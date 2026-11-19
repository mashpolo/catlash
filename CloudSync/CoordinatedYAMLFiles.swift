import Darwin
import Foundation

struct CoordinatedYAMLFiles: Sendable {
    static let maximumSize = 16 * 1024 * 1024
    let availability: @Sendable (URL) throws -> YAMLFileAvailability
    let versions: @Sendable (URL) throws -> [YAMLConflictVersion]

    init(
        availability: @escaping @Sendable (URL) throws -> YAMLFileAvailability = { try Self.cloudAvailability($0) },
        versions: @escaping @Sendable (URL) throws -> [YAMLConflictVersion] = { try Self.conflictVersions($0) }
    ) {
        self.availability = availability
        self.versions = versions
    }

    func names(in directory: URL) throws -> Set<String> {
        try Self.checkDirectory(directory)
        return try coordinateRead(directory) { coordinated in
            let children = try FileManager.default.contentsOfDirectory(at: coordinated, includingPropertiesForKeys: nil)
            return Set(children.compactMap { child in
                let name = child.lastPathComponent
                if isYAMLFileName(name) { return name }
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    let original = String(name.dropFirst().dropLast(7))
                    if isYAMLFileName(original) { return original }
                }
                return nil
            })
        }
    }

    func read(_ url: URL) throws -> YAMLObservedFile {
        try coordinateRead(url) { try observe($0) }
    }

    func transfer(
        from source: URL, to destination: URL, expectedSource: String, expectedDestination: String?,
        backups: URL, validate: @Sendable (Data) throws -> Void
    ) throws -> String {
        var coordinationError: NSError?
        var outcome: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges,
                                       writingItemAt: destination, options: .forReplacing,
                                       error: &coordinationError) { sourceURL, destinationURL in
            outcome = Result {
                let original = try checkedContent(observe(sourceURL))
                let replaced = try checkedContent(observe(destinationURL))
                guard let original, original.hash == expectedSource,
                      replaced?.hash == expectedDestination else { throw YAMLSyncError.staleConflict }
                try validate(original.data)
                if let replaced { _ = try backup(replaced.data, in: backups) }
                try Self.atomicWrite(original.data, to: destinationURL)
                return original.hash
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw YAMLSyncError.unavailable("File coordination did not complete.") }
        return try outcome.get()
    }

    func removeLocal(_ local: URL, whenMissingFrom remoteDirectory: URL, expectedHash: String,
                     backups: URL, beforeRemoval: () throws -> Void) throws {
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: remoteDirectory, options: .withoutChanges,
                                       writingItemAt: local, options: .forDeleting,
                                       error: &coordinationError) { directory, destination in
            outcome = Result {
                try Self.checkDirectory(directory)
                try Self.checkDirectory(destination.deletingLastPathComponent())
                let cloud = try directory.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                                                    .ubiquitousItemDownloadingErrorKey])
                if cloud.isUbiquitousItem == true {
                    if let error = cloud.ubiquitousItemDownloadingError { throw error }
                    if let status = cloud.ubiquitousItemDownloadingStatus, status != .current {
                        try FileManager.default.startDownloadingUbiquitousItem(at: directory)
                        throw YAMLSyncError.waitingDownload
                    }
                }
                let name = local.lastPathComponent
                let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                guard !names.contains("." + name + ".icloud") else { throw YAMLSyncError.waitingDownload }
                let remote = try checkedContent(observe(directory.appendingPathComponent(name)))
                guard !names.contains(name), remote == nil,
                      let current = try checkedContent(observe(destination)), current.hash == expectedHash else {
                    throw YAMLSyncError.staleConflict
                }
                _ = try backup(current.data, in: backups)
                try beforeRemoval()
                try FileManager.default.removeItem(at: destination)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw YAMLSyncError.unavailable("File coordination did not complete.") }
        try outcome.get()
    }

    func preserveVersions(_ versions: [YAMLConflictVersion], in directory: URL) throws -> [YAMLConflictVersion] {
        try versions.map { version in
            var preserved = version
            if let data = version.data { preserved.backupURL = try backup(data, in: directory) }
            return preserved
        }
    }

    private func observe(_ url: URL) throws -> YAMLObservedFile {
        if try availability(url) == .waitingDownload { return .waitingDownload }
        let conflicts = try versions(url)
        if !conflicts.isEmpty { return .versions(conflicts) }
        guard let data = try Self.readBytes(url) else { return .missing }
        let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return .ready(YAMLFileContent(data: data, hash: yamlDigest(data), modified: date))
    }

    private func checkedContent(_ observation: YAMLObservedFile) throws -> YAMLFileContent? {
        switch observation {
        case .ready(let content): return content
        case .missing: return nil
        case .waitingDownload: throw YAMLSyncError.waitingDownload
        case .versions: throw YAMLSyncError.unresolvedVersions
        }
    }

    private func backup(_ data: Data, in directory: URL) throws -> URL {
        try Self.createDirectory(directory)
        let destination = directory.appendingPathComponent(yamlDigest(data) + ".yaml")
        if let existing = try Self.readBytes(destination), existing == data { return destination }
        try Self.atomicWrite(data, to: destination)
        return destination
    }

    private func coordinateRead<T>(_ url: URL, body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var outcome: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinated in
            outcome = Result { try body(coordinated) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw YAMLSyncError.unavailable("File coordination did not complete.") }
        return try outcome.get()
    }

    static func checkDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw YAMLSyncError.invalidDirectory }
    }

    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try checkDirectory(url)
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }

    static func readBytes(_ url: URL) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw YAMLSyncError.invalidFile }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(.EIO) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw YAMLSyncError.invalidFile }
        guard info.st_size <= maximumSize else { throw YAMLSyncError.oversizedFile }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumSize + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumSize else { throw YAMLSyncError.oversizedFile }
        }
        return data
    }

    static func cloudAvailability(_ url: URL) throws -> YAMLFileAvailability {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            return .waitingDownload
        }
        do {
            let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                                           .ubiquitousItemDownloadingErrorKey])
            guard values.isUbiquitousItem == true else { return .available }
            if let error = values.ubiquitousItemDownloadingError { throw YAMLSyncError.unavailable(error.localizedDescription) }
            guard values.ubiquitousItemDownloadingStatus == .current else {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                return .waitingDownload
            }
            return .available
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .available
        }
    }

    static func conflictVersions(_ url: URL) throws -> [YAMLConflictVersion] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map { version in
            let identifier = String(describing: version.persistentIdentifier)
            do {
                guard let data = try readBytes(version.url) else { throw CocoaError(.fileReadNoSuchFile) }
                return YAMLConflictVersion(identifier: identifier, modificationDate: version.modificationDate, data: data)
            } catch {
                return YAMLConflictVersion(identifier: identifier, modificationDate: version.modificationDate,
                                           data: nil, error: error.localizedDescription)
            }
        }
    }
}
