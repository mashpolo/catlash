import CryptoKit
import Foundation

public actor ProfileRepository {
    public nonisolated let yamlDirectory: URL
    private let root: URL
    private let downloader: any ProfileDownloader

    public init(root: URL, downloader: any ProfileDownloader = URLSessionProfileDownloader()) {
        self.root = root
        self.yamlDirectory = root.appendingPathComponent("yaml", isDirectory: true)
        self.downloader = downloader
    }

    public func importData(data: Data, name: String, sourceURL: URL? = nil) throws -> ProfileRecord {
        let document = try YAMLDocument.validate(data: data)
        let displayName = try validateName(name)
        if let sourceURL { try validateSubscriptionURL(sourceURL) }
        try prepareDirectory()
        let id = UUID().uuidString.lowercased() + ".yaml"
        let record = ProfileRecord(
            id: id, displayName: displayName, sourceURL: sourceURL,
            revisionSHA: digest(data), updatedAt: Date(),
            validationStatus: .pendingCoreValidation, overview: document,
            subscription: sourceURL == nil ? nil : SubscriptionMetadata()
        )
        try coordinateWrite(profileURL(id)) { try atomicWrite(data, to: $0) }
        try mutateMetadata {
            let order = normalizedOrder($0)
            $0.records[id] = record
            $0.order = order + [id]
        }
        return record
    }

    public func list() throws -> [ProfileRecord] { try refresh() }

    public func refresh() throws -> [ProfileRecord] {
        try prepareDirectory()
        return try mutateMetadata { metadata in
            let files = try coordinateRead(yamlDirectory) {
                try FileManager.default.contentsOfDirectory(
                    at: $0, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: .skipsHiddenFiles
                )
            }
            var discovered: [String: ProfileRecord] = [:]
            for file in files {
                let id = file.lastPathComponent
                guard (try? validateID(id)) != nil else { continue }
                let stored: (Data, Date)
                do {
                    stored = try coordinateRead(file) { url in
                        let data = try readYAML(url)
                        let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
                        return (data, date)
                    }
                } catch ProfileStoreError.unsafeFile {
                    continue
                } catch ProfileStoreError.tooLarge {
                    continue
                } catch ProfileStoreError.notFound {
                    continue
                }
                let revision = digest(stored.0)
                let existing = metadata.records[id]
                let document = try? YAMLDocument.validate(data: stored.0)
                let updatedAt = existing.flatMap { $0.revisionSHA == revision ? $0.updatedAt : nil } ?? stored.1
                discovered[id] = ProfileRecord(
                    id: id,
                    displayName: existing?.displayName ?? (id as NSString).deletingPathExtension,
                    sourceURL: existing?.sourceURL,
                    revisionSHA: revision,
                    updatedAt: updatedAt,
                    validationStatus: document == nil ? .invalidYAML : .pendingCoreValidation,
                    overview: document,
                    subscription: existing?.subscription
                )
            }
            metadata.records = discovered
            metadata.order = normalizedOrder(metadata)
            return metadata.order!.compactMap { discovered[$0] }
        }
    }

    public func data(id: String) throws -> Data {
        try validateID(id)
        return try coordinateRead(profileURL(id)) { try readYAML($0) }
    }

    public func update(id: String, data: Data, expectedRevision: String) throws -> ProfileRecord {
        try validateID(id)
        let document = try YAMLDocument.validate(data: data)
        try coordinateWrite(profileURL(id)) { url in
            guard digest(try readYAML(url)) == expectedRevision else { throw ProfileStoreError.staleRevision }
            try atomicWrite(data, to: url)
        }
        return try mutateMetadata { metadata in
            let previous = metadata.records[id]
            let record = ProfileRecord(
                id: id,
                displayName: previous?.displayName ?? (id as NSString).deletingPathExtension,
                sourceURL: previous?.sourceURL,
                revisionSHA: digest(data), updatedAt: Date(),
                validationStatus: .pendingCoreValidation, overview: document,
                subscription: previous?.subscription
            )
            metadata.records[id] = record
            return record
        }
    }

    public func rename(id: String, name: String) throws -> ProfileRecord {
        let displayName = try validateName(name)
        _ = try record(id: id)
        return try mutateMetadata { metadata in
            guard var record = metadata.records[id] else { throw ProfileStoreError.notFound }
            record.displayName = displayName
            metadata.records[id] = record
            return record
        }
    }

    public func duplicate(id: String, name: String? = nil) throws -> ProfileRecord {
        let original = try record(id: id)
        return try importData(
            data: data(id: id), name: name ?? original.displayName + " 副本", sourceURL: original.sourceURL
        )
    }

    public func delete(id: String, expectedRevision: String? = nil) throws {
        try validateID(id)
        try coordinateWrite(profileURL(id), options: .forDeleting) { url in
            try requireRegularFile(url)
            if let expectedRevision, digest(try readYAML(url)) != expectedRevision {
                throw ProfileStoreError.staleRevision
            }
            try FileManager.default.removeItem(at: url)
        }
        try mutateMetadata {
            _ = $0.records.removeValue(forKey: id)
            $0.order?.removeAll { $0 == id }
        }
    }

    public func reorder(ids: [String]) throws {
        _ = try refresh()
        try mutateMetadata { metadata in
            guard Set(ids).count == ids.count, ids.allSatisfy({ metadata.records[$0] != nil }) else {
                throw ProfileStoreError.staleRevision
            }
            let requested = Set(ids)
            metadata.order = ids + normalizedOrder(metadata).filter { !requested.contains($0) }
        }
    }

    public func setSubscriptionInterval(id: String, seconds: TimeInterval?) throws {
        let profile = try record(id: id)
        guard profile.sourceURL != nil else { throw ProfileStoreError.noSubscription }
        guard seconds == nil || (seconds!.isFinite && seconds! > 0) else { throw ProfileStoreError.invalidSubscriptionInterval }
        try mutateMetadata { metadata in
            var subscription = metadata.records[id]?.subscription ?? SubscriptionMetadata()
            subscription.interval = seconds
            metadata.records[id]?.subscription = subscription
        }
    }

    public func recordSubscriptionAttempt(id: String, expectedRevision: String, at date: Date = Date()) throws {
        let profile = try record(id: id)
        guard profile.revisionSHA == expectedRevision else { throw ProfileStoreError.staleRevision }
        guard profile.sourceURL != nil else { throw ProfileStoreError.noSubscription }
        try mutateMetadata { metadata in
            var subscription = metadata.records[id]?.subscription ?? SubscriptionMetadata()
            subscription.attemptedAt = date
            metadata.records[id]?.subscription = subscription
        }
    }

    public func importSubscription(_ candidate: SubscriptionDownload, name: String, sourceURL: URL) throws -> ProfileRecord {
        let profile = try importData(data: candidate.data, name: name, sourceURL: sourceURL)
        return try storeSubscription(candidate, id: profile.id)
    }

    public func applySubscription(_ candidate: SubscriptionDownload, id: String, expectedRevision: String) throws -> ProfileRecord {
        let profile = try record(id: id)
        guard profile.sourceURL != nil else { throw ProfileStoreError.noSubscription }
        _ = try update(id: id, data: candidate.data, expectedRevision: expectedRevision)
        return try storeSubscription(candidate, id: id)
    }

    private func storeSubscription(_ candidate: SubscriptionDownload, id: String) throws -> ProfileRecord {
        try mutateMetadata { metadata in
            guard var profile = metadata.records[id] else { throw ProfileStoreError.notFound }
            var subscription = profile.subscription ?? SubscriptionMetadata()
            subscription.usage = candidate.usage
            subscription.checkedAt = candidate.receivedAt
            profile.subscription = subscription
            metadata.records[id] = profile
            return profile
        }
    }

    public func fetchCandidate(from url: URL) async throws -> Data {
        try await fetchSubscriptionDownload(from: url).data
    }

    public func fetchSubscriptionDownload(from url: URL) async throws -> SubscriptionDownload {
        try validateSubscriptionURL(url)
        try Task.checkCancellation()
        let candidate: SubscriptionDownload
        do {
            candidate = try await downloader.downloadSubscription(from: url, maximumBytes: YAMLDocument.maximumBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProfileStoreError {
            throw error
        } catch let error as ProfileDownloadError {
            throw error
        } catch {
            throw ProfileStoreError.downloadFailed
        }
        try Task.checkCancellation()
        _ = try YAMLDocument.validate(data: candidate.data)
        return candidate
    }

    public func fetchSubscriptionCandidate(id: String, expectedRevision: String) async throws -> Data {
        try await fetchSubscriptionDownload(id: id, expectedRevision: expectedRevision).data
    }

    public func fetchSubscriptionDownload(id: String, expectedRevision: String) async throws -> SubscriptionDownload {
        let profile = try record(id: id)
        guard profile.revisionSHA == expectedRevision else { throw ProfileStoreError.staleRevision }
        guard let url = profile.sourceURL else { throw ProfileStoreError.noSubscription }
        let candidate = try await fetchSubscriptionDownload(from: url)
        guard digest(try data(id: id)) == expectedRevision else { throw ProfileStoreError.staleRevision }
        return candidate
    }

    private struct Metadata: Codable, Equatable {
        var version = 1
        var records: [String: ProfileRecord] = [:]
        var order: [String]?
    }

    private func normalizedOrder(_ metadata: Metadata) -> [String] {
        var seen: Set<String> = []
        return (metadata.order ?? []).filter { metadata.records[$0] != nil && seen.insert($0).inserted }
            + metadata.records.keys.filter { !seen.contains($0) }.sorted()
    }

    private func record(id: String) throws -> ProfileRecord {
        try validateID(id)
        guard let record = try refresh().first(where: { $0.id == id }) else { throw ProfileStoreError.notFound }
        return record
    }

    private func mutateMetadata<T>(_ operation: (inout Metadata) throws -> T) throws -> T {
        try coordinateWrite(root.appendingPathComponent("profiles.json")) { url in
            var metadata: Metadata
            if FileManager.default.fileExists(atPath: url.path) {
                try requireRegularFile(url)
                do { metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: url)) }
                catch { throw ProfileStoreError.invalidMetadata }
                guard metadata.version == 1,
                      metadata.records.allSatisfy({ key, value in key == value.id && (try? validateID(key)) != nil }) else {
                    throw ProfileStoreError.invalidMetadata
                }
            } else {
                metadata = Metadata()
            }
            let before = metadata
            let value = try operation(&metadata)
            if metadata != before {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                try atomicWrite(encoder.encode(metadata), to: url)
            }
            return value
        }
    }

    private func prepareDirectory() throws {
        try coordinateWrite(root) { url in
            try FileManager.default.createDirectory(at: url.appendingPathComponent("yaml", isDirectory: true), withIntermediateDirectories: true)
        }
    }

    private func profileURL(_ id: String) -> URL { yamlDirectory.appendingPathComponent(id) }

    private func validateID(_ id: String) throws {
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/"), !id.contains("\\"), !id.contains("\0"),
              id.utf8.count <= 255, ["yaml", "yml"].contains((id as NSString).pathExtension.lowercased()) else {
            throw ProfileStoreError.invalidProfileID
        }
    }

    private func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileStoreError.invalidName }
        return trimmed
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ProfileStoreError.unsafeFile }
    }

    private func readYAML(_ url: URL) throws -> Data {
        try requireRegularFile(url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= YAMLDocument.maximumBytes else { throw ProfileStoreError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= YAMLDocument.maximumBytes else { throw ProfileStoreError.tooLarge }
        return data
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        var options: Data.WritingOptions = .atomic
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }

    private func coordinateRead<T>(_ url: URL, operation: (URL) throws -> T) throws -> T {
        var result: Result<T, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        return try finishCoordination(result, error: coordinationError)
    }

    private func coordinateWrite<T>(_ url: URL, options: NSFileCoordinator.WritingOptions = [], operation: (URL) throws -> T) throws -> T {
        var result: Result<T, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        return try finishCoordination(result, error: coordinationError)
    }

    private func finishCoordination<T>(_ result: Result<T, Error>?, error: NSError?) throws -> T {
        do {
            if let error { throw error }
            guard let result else { throw ProfileStoreError.storageFailure }
            return try result.get()
        } catch let error as ProfileStoreError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw ProfileStoreError.notFound
        } catch {
            throw ProfileStoreError.storageFailure
        }
    }
}
