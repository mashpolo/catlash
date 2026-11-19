import Foundation
import MihomoBridge

public enum YAMLResourceActivation {
    public static func prepare(
        _ activation: TunnelLifecycle.Activation,
        snapshotRoot: @escaping @Sendable () throws -> URL,
        stateRoot: @escaping @Sendable () throws -> URL,
        completion: @escaping TunnelLifecycle.PreparationCompletion
    ) -> @Sendable () -> Void {
        let cancellation = ResourcePreparationCancellation()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let configuration = try RuntimeConfiguration.decode(activation.configuration)
                guard case let .mihomo(yaml, selections) = configuration.outbound else {
                    completion(.success(activation))
                    return
                }
                try cancellation.check()
                if configuration.allowDeferredResources {
                    completion(.success(activation))
                    return
                }
                let snapshots = try snapshotRoot()
                let bundles = ResourceBundleStore(root: snapshots.appendingPathComponent("Resources", isDirectory: true))
                let resourcePath = try configuration.resources.map { try bundles.directory(id: $0).path } ?? ""
                let storagePath = try configuration.profileID.map {
                    try CoreStateStore(root: stateRoot()).directory(profileID: $0).path
                } ?? ""
                let choices = String(decoding: try JSONEncoder().encode(selections), as: UTF8.self)
                var error: NSError?
                guard let preparation = MobileNewYAMLResourcePreparation(yaml, choices, resourcePath, storagePath,
                                                                         Int32(configuration.mtu), &error) else {
                    throw error ?? SnapshotStoreError.invalidResourceBundle
                }
                cancellation.install(preparation)
                try preparation.prepare()
                try cancellation.check()
                let prepared = try stageResources(preparation, for: activation, snapshotRoot: snapshots)
                try cancellation.check()
                completion(.success(prepared))
            } catch {
                completion(.failure(error))
            }
        }
        return { cancellation.cancel() }
    }

    static func stageResources(_ preparation: MobileResourcePreparation, for activation: TunnelLifecycle.Activation,
                               snapshotRoot: URL) throws -> TunnelLifecycle.Activation {
        let current = try RuntimeConfiguration.decode(activation.configuration)
        let storeURL = snapshotRoot.appendingPathComponent("Resources", isDirectory: true)
        let count = Int(preparation.resourceCount())
        let resourceID = count == 0 ? nil : try ResourceBundleStore(root: storeURL).stage(count: count) { index in
            let item = try preparation.resource(at: Int32(index))
            guard let kind = ResourceKind(rawValue: item.kind), let data = item.data else { throw ResourceBundleError.invalidEntry }
            return ResourceEntryData(kind: kind, name: item.name, data: data)
        }
        if resourceID == current.resources { return activation }
        let final = RuntimeConfiguration(version: current.version, mtu: current.mtu, outbound: current.outbound,
                                         resources: resourceID, profileID: current.profileID,
                                         allowDeferredResources: current.allowDeferredResources)
        let store = SnapshotStore(root: snapshotRoot)
        let baseline = try RuntimeConfiguration.decode(store.load(revision: activation.revision))
        let persisted = RuntimeConfiguration(version: final.version, mtu: final.mtu, outbound: baseline.outbound,
                                             resources: resourceID, profileID: final.profileID,
                                             allowDeferredResources: final.allowDeferredResources)
        let snapshot = try store.prepare(configuration: persisted)
        try store.recordResourcePreparation(source: activation.revision, prepared: snapshot.revision)
        return .init(revision: snapshot.revision, configuration: try JSONEncoder().encode(final))
    }
}

private final class ResourcePreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var preparation: MobileResourcePreparation?

    func install(_ preparation: MobileResourcePreparation) {
        let cancel = lock.withLock { self.preparation = preparation; return cancelled }
        if cancel { preparation.cancel() }
    }

    func cancel() {
        let current = lock.withLock { cancelled = true; return preparation }
        current?.cancel()
    }

    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}
