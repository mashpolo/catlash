import Foundation

public struct RevisionApplicationResult: Sendable {
    public let activeRevision: String?
    public let restoredPrevious: Bool
    public let error: Error?
}

public enum RevisionApplicationError: Error, LocalizedError {
    case disconnected
    case superseded
    case restorationFailed

    public var errorDescription: String? {
        switch self {
        case .disconnected: return "Connect the tunnel before applying a revision."
        case .superseded: return "A newer tunnel request superseded this operation."
        case .restorationFailed: return "The new revision failed, and the previous revision could not be restored."
        }
    }
}

public final class RevisionApplication: @unchecked Sendable {
    public typealias Completion = @Sendable (Error?) -> Void
    public typealias ApplyCompletion = @Sendable (RevisionApplicationResult) -> Void

    private final class Request: @unchecked Sendable {
        let generation: UInt64
        let revision: String
        var completion: ApplyCompletion?

        init(generation: UInt64, revision: String, completion: @escaping ApplyCompletion) {
            self.generation = generation
            self.revision = revision
            self.completion = completion
        }

        func finish(_ result: RevisionApplicationResult) {
            let callback = completion
            completion = nil
            callback?(result)
        }
    }

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueIdentity = UUID()
    private let load: @Sendable (String) throws -> Data
    private let lastSuccessful: @Sendable () throws -> String?
    private let startOperation: @Sendable (String, Data, @escaping Completion) -> Void
    private let startedRevision: @Sendable (String, @escaping @Sendable (String?) -> Void) -> Void
    private let stopOperation: @Sendable (@escaping Completion) -> Void
    private var generation: UInt64 = 0
    private var pending: Request?
    private var activeRevision: String?
    private var acceptsApply = false

    public init(
        queue: DispatchQueue = DispatchQueue(label: "FlClash.RevisionApplication"),
        load: @escaping @Sendable (String) throws -> Data,
        lastSuccessful: @escaping @Sendable () throws -> String?,
        start: @escaping @Sendable (String, Data, @escaping Completion) -> Void,
        stop: @escaping @Sendable (@escaping Completion) -> Void,
        startedRevision: @escaping @Sendable (String, @escaping @Sendable (String?) -> Void) -> Void = { revision, completion in completion(revision) }
    ) {
        self.queue = queue
        self.load = load
        self.lastSuccessful = lastSuccessful
        startOperation = start
        stopOperation = stop
        self.startedRevision = startedRevision
        queue.setSpecific(key: queueKey, value: queueIdentity)
    }

    public func start(revision: String, completion: @escaping Completion) {
        onQueue {
            do {
                let data = try self.load(revision)
                self.acceptsApply = false
                let request = self.begin(revision: revision) { completion($0.error) }
                self.activate(request, data: data, restoring: nil)
            } catch { completion(error) }
        }
    }

    public func apply(revision: String, completion: @escaping ApplyCompletion) {
        onQueue {
            guard self.acceptsApply else {
                completion(self.result(error: RevisionApplicationError.disconnected))
                return
            }
            do {
                let data = try self.load(revision)
                let previous = try self.lastSuccessful() ?? self.activeRevision
                let request = self.begin(revision: revision, completion: completion)
                self.activate(request, data: data, restoring: previous)
            } catch { completion(self.result(error: error)) }
        }
    }

    public func stop(completion: @escaping Completion) {
        onQueue {
            self.invalidateState(error: RevisionApplicationError.superseded)
            self.stopOperation(completion)
        }
    }

    public func invalidate(error: Error) {
        onQueue { self.invalidateState(error: error) }
    }

    public func readActiveRevision(_ completion: @escaping @Sendable (String?) -> Void) {
        onQueue { completion(self.activeRevision) }
    }

    public func controlResponse(_ response: TunnelControlResponse, isCurrentSession: @escaping @Sendable () -> Bool,
                                completion: @escaping @Sendable (TunnelControlResponse) -> Void) {
        onQueue {
            guard let revision = self.activeRevision, isCurrentSession() else {
                completion(TunnelControlResponse(id: response.id, error: "The tunnel session changed."))
                return
            }
            completion(TunnelControlResponse(
                id: response.id, catalog: response.catalog, delayMilliseconds: response.delayMilliseconds,
                error: response.error, activeRevision: revision,
                restoredPrevious: response.restoredPrevious, metrics: response.metrics, runtime: response.runtime, sharing: response.sharing, exitIP: response.exitIP, delayFailure: response.delayFailure,
                resourceStatus: response.resourceStatus, configurationPage: response.configurationPage,
                providers: response.providers, inspectionSessionID: response.inspectionSessionID
            ))
        }
    }

    private func onQueue(_ operation: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == queueIdentity { operation() }
        else { queue.async(execute: operation) }
    }

    private func begin(revision: String, completion: @escaping ApplyCompletion) -> Request {
        generation &+= 1
        pending?.finish(result(error: RevisionApplicationError.superseded))
        let request = Request(generation: generation, revision: revision, completion: completion)
        pending = request
        activeRevision = nil
        return request
    }

    private func activate(_ request: Request, data: Data, restoring previous: String?) {
        startOperation(request.revision, data) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.generation == request.generation else { return }
                guard let error else {
                    self.finishStarted(request, revision: request.revision, restored: false, error: nil)
                    return
                }
                if case TunnelLifecycleError.cleanupFailed = error {
                    self.finish(request, active: nil, restored: false, error: error)
                    return
                }
                guard let previous, previous != request.revision else {
                    self.finish(request, active: nil, restored: false, error: error)
                    return
                }
                self.restore(previous, for: request, originalError: error)
            }
        }
    }

    private func restore(_ revision: String, for request: Request, originalError: Error) {
        do {
            let data = try load(revision)
            startOperation(revision, data) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard self.generation == request.generation else { return }
                    if error == nil {
                        self.finishStarted(request, revision: revision, restored: true, error: originalError)
                    } else {
                        self.finish(request, active: nil, restored: false, error: RevisionApplicationError.restorationFailed)
                    }
                }
            }
        } catch {
            finish(request, active: nil, restored: false, error: RevisionApplicationError.restorationFailed)
        }
    }

    private func finishStarted(_ request: Request, revision: String, restored: Bool, error: Error?) {
        startedRevision(revision) { [weak self] active in
            guard let self else { return }
            self.queue.async {
                guard self.generation == request.generation else { return }
                self.finish(request, active: active, restored: restored && active != nil,
                            error: active == nil ? RevisionApplicationError.disconnected : error)
            }
        }
    }

    private func finish(_ request: Request, active: String?, restored: Bool, error: Error?) {
        activeRevision = active
        acceptsApply = active != nil
        pending = nil
        request.finish(RevisionApplicationResult(activeRevision: active, restoredPrevious: restored, error: error))
    }

    private func invalidateState(error: Error) {
        generation &+= 1
        acceptsApply = false
        activeRevision = nil
        pending?.finish(result(error: error))
        pending = nil
    }

    private func result(error: Error) -> RevisionApplicationResult {
        RevisionApplicationResult(activeRevision: activeRevision, restoredPrevious: false, error: error)
    }
}
