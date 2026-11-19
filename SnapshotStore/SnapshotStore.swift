import CryptoKit
import Foundation

public struct SnapshotStore: Sendable {
    public struct PreparedSnapshot: Sendable {
        public let revision: String
        fileprivate let rootPath: String
        fileprivate init(revision: String, rootPath: String) {
            self.revision = revision
            self.rootPath = rootPath
        }
    }

    public struct ResourceAdoption: Sendable {
        fileprivate let source: String
        fileprivate let prepared: PreparedSnapshot
    }

    private let root: URL

    public init(root: URL) { self.root = root }

    public func stage(configuration: RuntimeConfiguration) throws -> String {
        try commit(prepare(configuration: configuration))
    }

    public func stage(data: Data) throws -> String {
        try commit(prepare(data: data))
    }

    public func prepare(configuration: RuntimeConfiguration) throws -> PreparedSnapshot {
        try configuration.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try prepare(data: encoder.encode(configuration))
    }

    public func prepare(data: Data) throws -> PreparedSnapshot {
        _ = try RuntimeConfiguration.decode(data)
        let revision = digest(data)
        let directory = root.appendingPathComponent("snapshots", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SnapshotStoreError.storageFailure
        }
        let destination = snapshotURL(revision)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try load(revision: revision)
        } else {
            try write(data, to: destination)
        }
        return PreparedSnapshot(revision: revision, rootPath: root.standardizedFileURL.path)
    }

    @discardableResult
    public func commit(_ prepared: PreparedSnapshot) throws -> String {
        guard prepared.rootPath == root.standardizedFileURL.path else { throw SnapshotStoreError.invalidRevision }
        try writeReference(prepared.revision, name: "pending")
        return prepared.revision
    }

    public func load(revision: String) throws -> Data {
        try readSnapshot(revision: revision).data
    }

    public func loadForActivation(revision: String) throws -> Data {
        let snapshot = try readSnapshot(revision: revision)
        if let resources = snapshot.configuration.resources {
            _ = try ResourceBundleStore(root: root.appendingPathComponent("Resources", isDirectory: true)).directory(id: resources)
        }
        return snapshot.data
    }

    private func readSnapshot(revision: String) throws -> (data: Data, configuration: RuntimeConfiguration) {
        try validateRevision(revision)
        guard let data = try read(snapshotURL(revision), maximumSize: RuntimeConfiguration.maximumSize) else {
            throw SnapshotStoreError.missingSnapshot
        }
        guard digest(data) == revision else { throw SnapshotStoreError.corruptSnapshot }
        return (data, try RuntimeConfiguration.decode(data))
    }

    public func recordResourcePreparation(source: String, prepared: String) throws {
        let original = try RuntimeConfiguration.decode(loadForActivation(revision: source))
        let final = try RuntimeConfiguration.decode(loadForActivation(revision: prepared))
        guard case .mihomo = original.outbound, original.allowDeferredResources || !final.allowDeferredResources,
              RuntimeConfiguration(version: original.version, mtu: original.mtu, outbound: original.outbound,
                                   resources: final.resources, profileID: original.profileID,
                                   allowDeferredResources: final.allowDeferredResources) == final else {
            throw SnapshotStoreError.invalidConfiguration
        }
        let directory = root.appendingPathComponent("resource-preparations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(Data([1]), to: directory.appendingPathComponent(source + "-" + prepared))
    }

    public func prepareSuccessfulResourceAdoption() throws -> ResourceAdoption? {
        guard let source = try pendingRevision(), let final = try lastSuccessfulRevision(), source != final else { return nil }
        let receipt = root.appendingPathComponent("resource-preparations").appendingPathComponent(source + "-" + final)
        guard try read(receipt, maximumSize: 1) == Data([1]) else { return nil }
        let data = try loadForActivation(revision: final)
        let original = try RuntimeConfiguration.decode(loadForActivation(revision: source))
        let completed = try RuntimeConfiguration.decode(data)
        guard original.allowDeferredResources || !completed.allowDeferredResources,
              RuntimeConfiguration(version: original.version, mtu: original.mtu, outbound: original.outbound,
                                   resources: completed.resources, profileID: original.profileID,
                                   allowDeferredResources: completed.allowDeferredResources) == completed else { return nil }
        return ResourceAdoption(source: source, prepared: try prepare(data: data))
    }

    fileprivate func adopt(_ proposal: ResourceAdoption) throws -> Bool {
        guard try read(root.appendingPathComponent("pending"), maximumSize: 64) == Data(proposal.source.utf8),
              try read(root.appendingPathComponent("last-successful"), maximumSize: 64) == Data(proposal.prepared.revision.utf8) else { return false }
        try commit(proposal.prepared)
        return true
    }

    public func pendingRevision() throws -> String? {
        try readReference(name: "pending")
    }

    public func lastSuccessfulRevision() throws -> String? {
        try readReference(name: "last-successful")
    }

    public func lastSuccessfulRevision(profileID: String, yaml: Data) throws -> String? {
        let indexed = try readReference(name: profileSuccessReference(profileID: profileID, yaml: yaml))
        guard let revision = try indexed ?? lastSuccessfulRevision() else { return nil }
        let configuration = try readSnapshot(revision: revision).configuration
        guard configuration.profileID == profileID,
              case let .mihomo(source, _) = configuration.outbound,
              source.utf8.elementsEqual(yaml) else { return nil }
        return revision
    }

    public func markSuccessful(revision: String) throws {
        let configuration = try RuntimeConfiguration.decode(loadForActivation(revision: revision))
        try writeReference(revision, name: "last-successful")
        // This index is only a cache hint. A failed cache write must not turn an
        // already successful activation into a failed lifecycle transition.
        if configuration.resources != nil, let profileID = configuration.profileID,
           case let .mihomo(yaml, _) = configuration.outbound {
            try? recordProfileSuccess(revision: revision, profileID: profileID, yaml: Data(yaml.utf8))
        }
    }

    private func recordProfileSuccess(revision: String, profileID: String, yaml: Data) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("profile-successes"), withIntermediateDirectories: true)
        try writeReference(revision, name: profileSuccessReference(profileID: profileID, yaml: yaml))
    }

    private func profileSuccessReference(profileID: String, yaml: Data) -> String {
        "profile-successes/" + digest(Data(profileID.utf8)) + "-" + digest(yaml)
    }

    public func restoreLastSuccessful() throws -> String {
        guard let revision = try lastSuccessfulRevision() else {
            throw SnapshotStoreError.noSuccessfulSnapshot
        }
        _ = try loadForActivation(revision: revision)
        try writeReference(revision, name: "pending")
        return revision
    }

    private func readReference(name: String) throws -> String? {
        guard let data = try read(root.appendingPathComponent(name), maximumSize: 64) else { return nil }
        guard let revision = String(data: data, encoding: .utf8) else { throw SnapshotStoreError.invalidRevision }
        _ = try load(revision: revision)
        return revision
    }

    private func writeReference(_ revision: String, name: String) throws {
        try write(Data(revision.utf8), to: root.appendingPathComponent(name))
    }

    private func snapshotURL(_ revision: String) -> URL {
        root.appendingPathComponent("snapshots", isDirectory: true).appendingPathComponent(revision + ".json")
    }

    private func validateRevision(_ revision: String) throws {
        guard revision.utf8.count == 64,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SnapshotStoreError.invalidRevision
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func read(_ url: URL, maximumSize: Int) throws -> Data? {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= maximumSize else {
                throw SnapshotStoreError.corruptSnapshot
            }
            let data = try Data(contentsOf: url)
            guard data.count <= maximumSize else { throw SnapshotStoreError.corruptSnapshot }
            return data
        } catch let error as SnapshotStoreError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw SnapshotStoreError.storageFailure
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        do {
            try data.write(to: url, options: options)
        } catch {
            throw SnapshotStoreError.storageFailure
        }
    }
}

@MainActor
public final class SnapshotCommitCoordinator {
    public struct Intent: Sendable {
        fileprivate let id: UUID
        fileprivate init(id: UUID) { self.id = id }
    }

    private var current = UUID()
    private var preparing = false

    public init() {}

    public func begin() -> Intent {
        let id = UUID()
        current = id
        preparing = true
        return Intent(id: id)
    }

    public func isCurrent(_ intent: Intent) -> Bool { current == intent.id }
    public func observe() -> Intent { Intent(id: current) }
    public func finish(_ intent: Intent) { if isCurrent(intent) { preparing = false } }

    public func adopt(_ proposal: SnapshotStore.ResourceAdoption, to store: SnapshotStore, observation: Intent) throws -> Bool {
        guard !preparing, isCurrent(observation) else { return false }
        return try store.adopt(proposal)
    }

    @discardableResult
    public func commit(_ prepared: SnapshotStore.PreparedSnapshot, to store: SnapshotStore, intent: Intent) throws -> String {
        try Task.checkCancellation()
        guard isCurrent(intent) else { throw CancellationError() }
        let revision = try store.commit(prepared)
        preparing = false
        return revision
    }
}
