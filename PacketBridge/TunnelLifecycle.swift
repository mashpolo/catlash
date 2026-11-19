import Foundation

public enum TunnelLifecycleError: Error, LocalizedError {
    case superseded
    case cleanupFailed(operation: String?, cleanup: String)

    public var errorDescription: String? {
        switch self {
        case .superseded: return "The tunnel request was superseded."
        case .cleanupFailed(let operation, let cleanup):
            return [operation, "Tunnel settings cleanup failed: \(cleanup)"].compactMap { $0 }.joined(separator: "; ")
        }
    }
}

public final class TunnelLifecycle: @unchecked Sendable {
    public typealias Completion = @Sendable (Error?) -> Void
    public struct Activation: Sendable {
        public let revision: String
        public let configuration: Data
        public init(revision: String, configuration: Data) {
            self.revision = revision
            self.configuration = configuration
        }
    }
    public typealias PreparationCompletion = @Sendable (Result<Activation, Error>) -> Void
    public typealias Prepare = @Sendable (Activation, @escaping PreparationCompletion) -> (@Sendable () -> Void)

    private final class Request: @unchecked Sendable {
        let generation: UInt64
        var revision: String
        var configuration: Data
        var completion: Completion?

        init(generation: UInt64, revision: String, configuration: Data, completion: @escaping Completion) {
            self.generation = generation
            self.revision = revision
            self.configuration = configuration
            self.completion = completion
        }

        func finish(_ error: Error?) {
            let callback = completion
            completion = nil
            callback?(error)
        }
    }

    private let queue = DispatchQueue(label: "FlClash.TunnelLifecycle")
    private let prepare: Prepare
    private var cancelPreparation: (@Sendable () -> Void)?
    private let installSettings: @Sendable (Data, @escaping Completion) -> Void
    private let clearSettings: @Sendable (@escaping Completion) -> Void
    private let makeSession: @Sendable (Data) throws -> PacketSession
    private let startPackets: @Sendable (PacketSession, @escaping Completion) -> Void
    private let stopPackets: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let didStart: @Sendable (String) throws -> Void
    private let onFailure: Completion
    private var generation: UInt64 = 0
    private var desired: Request?
    private var running: Request?
    private var activeRevision: String?
    private var busy = false
    private var settingsDirty = false
    private var stopCompletions: [Completion] = []
    private var failedStarts: [(Request, Error)] = []
    private var stopError: Error?

    public init(
        prepare: @escaping Prepare = { activation, completion in completion(.success(activation)); return {} },
        installSettings: @escaping @Sendable (Data, @escaping Completion) -> Void,
        clearSettings: @escaping @Sendable (@escaping Completion) -> Void,
        makeSession: @escaping @Sendable (Data) throws -> PacketSession,
        startPackets: @escaping @Sendable (PacketSession, @escaping Completion) -> Void,
        stopPackets: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
        didStart: @escaping @Sendable (String) throws -> Void,
        onFailure: @escaping Completion
    ) {
        self.prepare = prepare
        self.installSettings = installSettings
        self.clearSettings = clearSettings
        self.makeSession = makeSession
        self.startPackets = startPackets
        self.stopPackets = stopPackets
        self.didStart = didStart
        self.onFailure = onFailure
    }

    public func start(revision: String, configuration: Data, completion: @escaping Completion) {
        queue.async {
            self.generation &+= 1
            self.desired?.finish(TunnelLifecycleError.superseded)
            self.desired = Request(generation: self.generation, revision: revision, configuration: configuration, completion: completion)
            self.cancelPreparing()
            self.reconcile()
        }
    }

    public func stop(completion: @escaping Completion) {
        queue.async {
            self.generation &+= 1
            self.desired?.finish(TunnelLifecycleError.superseded)
            self.desired = nil
            self.stopCompletions.append(completion)
            self.cancelPreparing()
            self.reconcile()
        }
    }

    public func readActiveRevision(_ completion: @escaping @Sendable (String?) -> Void) {
        queue.async { completion(self.activeRevision) }
    }

    private func reconcile() {
        guard !busy else { return }
        if let running {
            guard desired?.generation != running.generation else { return }
            busy = true
            stopPackets {
                self.queue.async {
                    self.running = nil
                    self.activeRevision = nil
                    self.busy = false
                    self.reconcile()
                }
            }
            return
        }
        if settingsDirty {
            clear()
            return
        }
        completeRollback()
        guard let desired else { return }
        prepareActivation(desired)
    }

    private func cancelPreparing() {
        let cancel = cancelPreparation
        cancelPreparation = nil
        cancel?()
    }

    private func prepareActivation(_ request: Request) {
        busy = true
        cancelPreparation = prepare(.init(revision: request.revision, configuration: request.configuration)) { result in
            self.queue.async {
                self.cancelPreparation = nil
                self.busy = false
                guard self.desired?.generation == request.generation else {
                    self.reconcile()
                    return
                }
                switch result {
                case .success(let activation):
                    request.revision = activation.revision
                    request.configuration = activation.configuration
                    self.install(request)
                case .failure(let error):
                    self.fail(request, error: error)
                }
            }
        }
    }

    private func install(_ request: Request) {
        busy = true
        settingsDirty = true
        installSettings(request.configuration) { error in
            self.queue.async {
                self.busy = false
                guard self.desired?.generation == request.generation else {
                    self.reconcile()
                    return
                }
                if let error {
                    self.fail(request, error: error)
                    return
                }
                self.beginPackets(request)
            }
        }
    }

    private func beginPackets(_ request: Request) {
        do {
            let session = try makeSession(request.configuration)
            running = request
            startPackets(session) { [weak self] error in
                guard let self, let error else { return }
                self.queue.async {
                    guard self.running?.generation == request.generation else { return }
                    self.fail(request, error: error)
                }
            }
            try didStart(request.revision)
            activeRevision = request.revision
            request.finish(nil)
        } catch {
            fail(request, error: error)
        }
    }

    private func fail(_ request: Request, error: Error) {
        let isDesired = desired?.generation == request.generation
        if isDesired { desired = nil }
        if request.completion != nil {
            failedStarts.append((request, error))
        } else if isDesired {
            onFailure(error)
        }
        stopError = stopError ?? error
        reconcile()
    }

    private func clear() {
        busy = true
        clearSettings { error in
            self.queue.async {
                self.busy = false
                if let error {
                    let failure = TunnelLifecycleError.cleanupFailed(
                        operation: self.stopError?.localizedDescription,
                        cleanup: error.localizedDescription
                    )
                    self.desired?.finish(failure)
                    self.desired = nil
                    self.completeRollback(cleanupError: failure)
                    self.onFailure(failure)
                    return
                }
                self.settingsDirty = false
                self.reconcile()
            }
        }
    }

    private func completeRollback(cleanupError: Error? = nil) {
        let starts = failedStarts
        failedStarts.removeAll()
        starts.forEach { $0.0.finish(cleanupError ?? $0.1) }
        let completions = stopCompletions
        stopCompletions.removeAll()
        let error = cleanupError ?? stopError
        stopError = nil
        completions.forEach { $0(error) }
    }
}
