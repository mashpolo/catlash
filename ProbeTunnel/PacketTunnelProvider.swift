import Foundation
import NetworkExtension
import MihomoBridge

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "FlClash.PacketTunnelProvider")
    private let controlQueue = DispatchQueue(label: "FlClash.TunnelControl")
    private let exitIPQueue = DispatchQueue(label: "FlClash.ExitIP", attributes: .concurrent)
    private let testQueue = DispatchQueue(label: "FlClash.TunnelTests", attributes: .concurrent)
    private let sessions = ActiveGoSession()
    private var countedFlow: CountingPacketFlow?
    private var lastError: String?
    private var intentGeneration: UInt64 = 0
    private var exitIPRequestID: Int64 = 0
    private var canApply = false
    private var tunnelReady = false
    private var pendingControls: [UUID: PendingControl] = [:]
    private var startupDiagnostics: TunnelStartupDiagnosticsStore?
    private var startupAttemptID: UUID?
    private let selectionOverrides = RuntimeSelectionOverrides()
    private var resourcePreparation: GoResourcePreparation?
    private var resourceMemoryMonitor: ResourceMemoryMonitor?
    private var resourceGeneration: UInt64 = 0
    private var startupResourceStatus: TunnelResourceStatus?
    private var providerUpdateStatus: TunnelResourceStatus?
    private var resourceJobRunning: Bool {
        startupResourceStatus?.phase == .preparing || startupResourceStatus?.phase == .applying || providerUpdateStatus?.phase == .preparing
    }
    private var attemptedResourceRevisions: Set<String> = []
    private lazy var lifecycle = makeLifecycle()
    private lazy var application = makeApplication()

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping @Sendable (Error?) -> Void) {
        let requestedRevision = options?["revision"] as? String
        let attemptID = (options?["attemptID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let selectionData = options?["selections"] as? Data
        stateQueue.async { [self] in
            let generation = self.beginIntent()
            self.canApply = false
            self.lastError = nil
            self.attemptedResourceRevisions.removeAll()
            self.startupAttemptID = attemptID
            if self.startupDiagnostics == nil, let root = try? Self.groupDirectory() {
                self.startupDiagnostics = TunnelStartupDiagnosticsStore(root: root)
            }
            let configuration = self.protocolConfiguration as? NETunnelProviderProtocol
            let selectedRevision = requestedRevision ?? configuration?.providerConfiguration?["revision"] as? String
            try? self.startupDiagnostics?.begin(attemptID: attemptID, revision: selectedRevision)
            do {
                guard let revision = selectedRevision else {
                    throw ProviderError.missingRevision
                }
                // Capture physical-network DNS before installing virtual tunnel DNS.
                // The core uses it only for an explicitly configured system:// entry.
                let systemDNS = try JSONEncoder().encode(FlClashSystemDNSServers())
                var systemDNSError: NSError?
                _ = MobileSetSystemDNSServersJSON(String(decoding: systemDNS, as: UTF8.self), &systemDNSError)
                if let systemDNSError { throw systemDNSError }
                try GoPacketSession.registerBundledGeodata()
                self.selectionOverrides.reset()
                if let selectionData {
                    try self.selectionOverrides.set(RuntimeSelectionOverrides.decode(selectionData), revision: revision)
                }
                try? self.startupDiagnostics?.record(attemptID: attemptID, phase: .starting)
                self.application.start(revision: revision) { [weak self] error in
                    guard let self else { completionHandler(error ?? ProviderError.unavailable); return }
                    self.stateQueue.async {
                        if self.intentGeneration == generation {
                            self.lastError = error?.localizedDescription
                            self.canApply = error == nil
                            self.tunnelReady = error == nil
                            try? self.startupDiagnostics?.record(attemptID: attemptID, phase: error == nil ? .connected : .failed, error: error)
                        }
                        completionHandler(error)
                        if error == nil, self.intentGeneration == generation { self.completePendingResources() }
                    }
                }
            } catch {
                self.lastError = error.localizedDescription
                try? self.startupDiagnostics?.record(attemptID: attemptID, phase: .failed, error: error)
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping @Sendable () -> Void) {
        stateQueue.async { [self] in
            _ = self.beginIntent()
            let attemptID = self.startupAttemptID
            self.canApply = false
            self.application.stop { [weak self] error in
                guard let self else { completionHandler(); return }
                self.stateQueue.async {
                    if let attemptID {
                        try? self.startupDiagnostics?.record(attemptID: attemptID, phase: error == nil ? .stopped : .failed, error: error, stopReason: reason)
                    }
                    if let error {
                        self.lastError = error.localizedDescription
                        self.cancelTunnelWithError(error)
                    }
                    completionHandler()
                }
            }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: (@Sendable (Data?) -> Void)? = nil) {
        guard let completionHandler else { return }
        stateQueue.async { [self] in
            if messageData == Data("counters".utf8) {
                self.readCounters(completionHandler)
                return
            }
            guard messageData.count <= 16_384,
                  let request = try? JSONDecoder().decode(TunnelControlRequest.self, from: messageData) else {
                completionHandler(nil)
                return
            }
            guard self.pendingControls[request.id] == nil,
                  self.pendingControls.count < 32 || request.action == .cancelExitIP else {
                completionHandler(Self.encode(TunnelControlResponse(id: request.id, error: "Too many pending control requests.")))
                return
            }
            if request.action == .applyRevision {
                // Switching back to a profile gets a new attempt at its deferred rules.
                self.attemptedResourceRevisions.removeAll()
                self.apply(request, completion: completionHandler)
            } else if request.action == .refreshProvider {
                guard self.canApply, self.tunnelReady, let ticket = self.sessions.current(),
                      request.expectedSessionID == ticket.id.uuidString,
                      let kind = request.providerKind, [.proxyProvider, .ruleProvider].contains(kind),
                      let name = request.providerName, !name.isEmpty, name.utf8.count <= 4096 else {
                    completionHandler(Self.encode(.init(id: request.id, error: "运行会话或来源已改变，请刷新列表。")))
                    return
                }
                self.application.readActiveRevision { revision in
                    guard self.sessions.isCurrent(ticket), let revision, revision == request.revision else {
                        completionHandler(Self.encode(.init(id: request.id, error: "运行配置已改变，请刷新列表。")))
                        return
                    }
                    guard !self.resourceJobRunning else {
                        completionHandler(Self.encode(.init(id: request.id, error: "正在更新资源，请在完成后再试。")))
                        return
                    }
                    self.updateProvider(kind: kind, name: name, ticket: ticket, operationID: request.id)
                    completionHandler(Self.encode(.init(id: request.id, activeRevision: revision,
                                                       resourceStatus: self.providerUpdateStatus, inspectionSessionID: ticket.id.uuidString)))
                }
            } else if request.action == .refreshResources {
                guard self.canApply, self.tunnelReady else {
                    completionHandler(Self.encode(TunnelControlResponse(id: request.id, error: "VPN 尚未连接。")))
                    return
                }
                // A simultaneous refresh joins the resource job already owned by this session.
                if !self.resourceJobRunning {
                    self.completePendingResources(force: true)
                }
                completionHandler(Self.encode(TunnelControlResponse(id: request.id, resourceStatus: self.startupResourceStatus)))
            } else {
                self.control(request, completion: completionHandler)
            }
        }
    }

    private func beginIntent() -> UInt64 {
        startupResourceStatus = nil
        providerUpdateStatus = nil
        resourceMemoryMonitor = nil
        resourceGeneration &+= 1
        resourcePreparation?.cancel()
        resourcePreparation = nil
        intentGeneration &+= 1
        tunnelReady = false
        for id in Array(pendingControls.keys) {
            finishControl(TunnelControlResponse(id: id, error: "A newer tunnel request superseded this operation."))
        }
        return intentGeneration
    }

    private func apply(_ request: TunnelControlRequest, completion: @escaping @Sendable (Data?) -> Void) {
        guard canApply, let revision = request.revision else {
            completion(Self.encode(TunnelControlResponse(id: request.id, error: "Connect the tunnel and choose a revision first.")))
            return
        }
        do { try selectionOverrides.set(request.selections, revision: revision) }
        catch {
            completion(Self.encode(TunnelControlResponse(id: request.id, error: error.localizedDescription)))
            return
        }
        let generation = beginIntent()
        pendingControls[request.id] = PendingControl(action: request.action, completion: completion)
        application.apply(revision: revision) { [weak self] result in
            guard let self else { return }
            self.stateQueue.async {
                guard self.intentGeneration == generation else { return }
                self.canApply = result.activeRevision != nil
                self.tunnelReady = self.canApply
                self.lastError = result.error?.localizedDescription
                if result.error != nil, self.canApply, let ticket = self.sessions.current() {
                    self.startupResourceStatus = ticket.session.resourcesPending
                        ? .init(phase: .failed, message: "部分配置资源尚未加载，可重试。")
                        : .init(phase: .ready, message: "配置资源已就绪。")
                }
                self.finishControl(TunnelControlResponse(
                    id: request.id, error: result.error?.localizedDescription,
                    activeRevision: result.activeRevision, restoredPrevious: result.restoredPrevious
                ))
                if result.error == nil { self.completePendingResources() }
                if result.activeRevision == nil, let error = result.error {
                    if let attemptID = self.startupAttemptID {
                        try? self.startupDiagnostics?.record(attemptID: attemptID, phase: .failed, error: error)
                    }
                    self.cancelTunnelWithError(error)
                }
            }
        }
    }

    private func control(_ request: TunnelControlRequest, completion: @escaping @Sendable (Data?) -> Void) {
        let delaySettings = request.delaySettings ?? ProxyDelaySettings()
        if request.action == .delay {
            do { try delaySettings.validate() }
            catch {
                completion(Self.encode(TunnelControlResponse(id: request.id, error: error.localizedDescription)))
                return
            }
        }
        guard tunnelReady, let ticket = sessions.current() else {
            completion(Self.encode(TunnelControlResponse(id: request.id, error: "The tunnel is not ready.")))
            return
        }
        if request.action == .cancelExitIP {
            if let cancelledID = request.cancellingRequestID,
               let queryID = pendingControls[cancelledID]?.exitIPRequestID {
                ticket.session.cancelExitIP(requestID: queryID)
                finishControl(TunnelControlResponse(id: cancelledID, error: "The exit IP query was cancelled."))
            }
            completion(Self.encode(TunnelControlResponse(id: request.id)))
            return
        }
        if request.action == .cancelTests {
            sessions.cancelTestIntent()
            for (id, pending) in pendingControls where pending.action == .delay {
                finishControl(TunnelControlResponse(id: id, error: "The latency test was cancelled."))
            }
        }
        if request.action == .exitIP { exitIPRequestID &+= 1 }
        let queryID = exitIPRequestID
        pendingControls[request.id] = PendingControl(action: request.action, completion: completion,
                                                     exitIPRequestID: request.action == .exitIP ? queryID : nil)
        let timeout = request.action == .exitIP ? 23.0 : request.action == .delay ? delaySettings.extensionTimeout : 5.0
        stateQueue.asyncAfter(deadline: .now() + timeout) { [weak self, weak querySession = ticket.session] in
            guard let self, self.pendingControls[request.id] != nil else { return }
            if request.action == .exitIP { querySession?.cancelExitIP(requestID: queryID) }
            if request.action == .delay {
                self.application.controlResponse(TunnelControlResponse(id: request.id, delayFailure: .timeout),
                    isCurrentSession: { self.sessions.isCurrent(ticket) }, completion: { self.finishControl($0) })
            } else {
                self.finishControl(TunnelControlResponse(id: request.id, error: "The tunnel control request timed out."))
            }
        }
        let workerQueue = request.action == .exitIP ? exitIPQueue : request.action == .delay ? testQueue : controlQueue
        workerQueue.async { [weak self] in
            guard let self else { return }
            let response: TunnelControlResponse
            do {
                guard self.sessions.isCurrent(ticket),
                      request.action != .delay || self.sessions.isCurrentTest(ticket) else { throw ProviderError.unavailable }
                switch request.action {
                case .effectiveConfiguration:
                    let page = try ticket.session.configurationPage(offset: request.offset ?? 0, expectedID: request.expectedSessionID)
                    response = .init(id: request.id, configurationPage: page)
                case .providerCatalog:
                    response = .init(id: request.id, providers: try ticket.session.providers(), inspectionSessionID: ticket.id.uuidString)
                case .catalog:
                    response = TunnelControlResponse(id: request.id, catalog: try ticket.session.proxyCatalog())
                case .exitIP:
                    response = TunnelControlResponse(id: request.id, exitIP: try ticket.session.exitIP(requestID: queryID, forceRefresh: request.forceRefresh == true))
                case .setMode:
                    ticket.session.cancelExitIP()
                    guard let mode = request.mode else { throw ProviderError.invalidRequest }
                    try ticket.session.setMode(mode)
                    response = TunnelControlResponse(id: request.id, catalog: try ticket.session.proxyCatalog())
                case .select:
                    ticket.session.cancelExitIP()
                    guard let group = request.group, let node = request.node else { throw ProviderError.invalidRequest }
                    try ticket.session.selectProxy(group: group, name: node)
                    response = TunnelControlResponse(id: request.id, catalog: try ticket.session.proxyCatalog())
                case .delay:
                    guard let node = request.node else { throw ProviderError.invalidRequest }
                    response = TunnelControlResponse(id: request.id, delayMilliseconds: try ticket.session.testProxy(name: node, settings: delaySettings))
                case .cancelTests:
                    ticket.session.cancelTests()
                    response = TunnelControlResponse(id: request.id)
                case .metrics:
                    response = TunnelControlResponse(id: request.id, metrics: try ProcessMetrics.snapshot())
                case .runtimeSnapshot:
                    response = TunnelControlResponse(id: request.id, runtime: try ticket.session.runtimeSnapshot())
                case .closeConnection:
                    guard let id = request.connectionID, !id.isEmpty, id.utf8.count <= 128 else { throw ProviderError.invalidRequest }
                    try ticket.session.closeConnection(id: id)
                    response = TunnelControlResponse(id: request.id, runtime: try ticket.session.runtimeSnapshot())
                case .closeAllConnections, .clearDNSCache:
                    guard let sessionID = request.expectedSessionID, !sessionID.isEmpty, sessionID.utf8.count <= 128 else { throw ProviderError.invalidRequest }
                    if request.action == .closeAllConnections {
                        try ticket.session.closeAllConnections(expectedSessionID: sessionID)
                    } else {
                        try ticket.session.clearDNSCache(expectedSessionID: sessionID)
                    }
                    response = TunnelControlResponse(id: request.id, runtime: try ticket.session.runtimeSnapshot())
                case .sharingStatus:
                    response = TunnelControlResponse(id: request.id, sharing: try ticket.session.sharingStatus())
                case .configureSharing:
                    guard let configuration = request.sharingConfiguration else { throw ProviderError.invalidRequest }
                    response = TunnelControlResponse(id: request.id, sharing: try ticket.session.configureSharing(configuration))
                case .applyRevision, .cancelExitIP, .refreshResources, .refreshProvider:
                    throw ProviderError.invalidRequest
                }
            } catch let failure as ProxyDelayFailure {
                response = TunnelControlResponse(id: request.id, delayFailure: failure)
            } catch {
                response = TunnelControlResponse(id: request.id, error: request.action == .exitIP ? error.localizedDescription : "The tunnel control operation failed or was cancelled.")
            }
            self.stateQueue.async {
                guard self.sessions.isCurrent(ticket) else {
                    self.finishControl(TunnelControlResponse(id: request.id, error: "The tunnel session changed."))
                    return
                }
                self.application.controlResponse(response, isCurrentSession: { self.sessions.isCurrent(ticket) },
                                                 completion: { result in
                    if request.action == .select, result.error == nil, let revision = result.activeRevision,
                       let group = request.group, let node = request.node {
                        self.selectionOverrides.select(group: group, node: node, revision: revision)
                    }
                    self.finishControl(result)
                    if request.action == .select, result.error == nil, self.startupResourceStatus?.phase == .failed,
                       !self.resourceJobRunning {
                        self.completePendingResources(force: true)
                    }
                })
            }
        }
    }

    private func finishControl(_ response: TunnelControlResponse) {
        guard let pending = pendingControls.removeValue(forKey: response.id) else { return }
        let status = pending.action == .providerCatalog ? providerUpdateStatus : startupResourceStatus
        pending.completion(Self.encode(response.withResourceStatus(status)))
    }

    private func completePendingResources(force: Bool = false) {
        guard canApply, tunnelReady, let ticket = sessions.current() else { return }
        guard ticket.session.resourcesPending else {
            startupResourceStatus = .init(phase: .ready, message: "配置资源已就绪。")
            return
        }
        if resourcePreparation != nil, !force { return }
        resourceMemoryMonitor = nil
        resourceGeneration &+= 1
        let generation = resourceGeneration
        let intent = intentGeneration
        resourcePreparation?.cancel()
        resourcePreparation = nil
        // Reserve the shared resource job before the asynchronous revision lookup.
        let previousStatus = startupResourceStatus
        startupResourceStatus = .init(phase: .preparing, message: "VPN 已连接，Mihomo 正在加载配置引用的规则。")
        lifecycle.readActiveRevision { [weak self] revision in
            guard let self else { return }
            self.stateQueue.async {
                guard self.resourceGeneration == generation, self.intentGeneration == intent,
                      self.sessions.isCurrent(ticket) else { return }
                guard let revision, force || !self.attemptedResourceRevisions.contains(revision) else {
                    self.startupResourceStatus = previousStatus
                    return
                }
                self.attemptedResourceRevisions.insert(revision)
                do {
                    let snapshots = try Self.snapshotDirectory()
                    let data = try self.selectionOverrides.configuration(Self.snapshotStore().loadForActivation(revision: revision), revision: revision)
                    let configuration = try RuntimeConfiguration.decode(data)
                    let resourceRoot = try configuration.resources.map {
                        try ResourceBundleStore(root: snapshots.appendingPathComponent("Resources")).directory(id: $0)
                    }
                    let stateRoot = try configuration.profileID.map {
                        try CoreStateStore(root: Self.groupDirectory().appendingPathComponent("CoreState")).directory(profileID: $0)
                    }
                    guard let budget = try self.resourceMemoryBudget(generation: generation) else { return }
                    let preparation = try ticket.session.makeResourcePreparation(
                        configuration: configuration, resourceRoot: resourceRoot, stateRoot: stateRoot
                    )
                    preparation.setMemoryBudget(budget)
                    self.resourcePreparation = preparation
                    let activation = TunnelLifecycle.Activation(revision: revision, configuration: data)
                    DispatchQueue.global(qos: .utility).async {
                        let result: Result<TunnelLifecycle.Activation, Error>
                        do {
                            result = .success(try preparation.prepare(for: activation, snapshotRoot: snapshots))
                        } catch { result = .failure(error) }
                        self.stateQueue.async {
                            guard self.resourceGeneration == generation, self.intentGeneration == intent,
                                  self.sessions.isCurrent(ticket) else { return }
                            self.resourcePreparation = nil
                            self.resourceMemoryMonitor = nil
                            do {
                                let prepared = try result.get()
                                let latest = try self.selectionOverrides.configuration(prepared.configuration, revision: revision)
                                try self.selectionOverrides.rememberPrepared(source: revision, prepared: prepared.revision, configuration: latest)
                                let runtime = try RuntimeConfiguration.decode(latest)
                                guard case let .mihomo(_, selections) = runtime.outbound else { throw ProviderError.invalidConfiguration }
                                self.startupResourceStatus = .init(phase: .applying, message: "资源已下载，正在自动应用完整配置。")
                                let applyIntent = self.intentGeneration &+ 1
                                self.apply(.init(action: .applyRevision, revision: prepared.revision, selections: selections)) { response in
                                    guard self.intentGeneration == applyIntent else { return }
                                    if let response, let value = try? JSONDecoder().decode(TunnelControlResponse.self, from: response), value.error == nil {
                                        self.startupResourceStatus = .init(phase: .ready, message: "配置资源已就绪。")
                                    } else {
                                        self.startupResourceStatus = .init(phase: .failed, message: "完整配置应用失败，VPN 继续使用之前的配置，可重试资源。")
                                    }
                                }
                            } catch { self.resourceCompletionFailed(error) }
                        }
                    }
                } catch { self.resourceCompletionFailed(error) }
            }
        }
    }

    private static func memoryPressureStatus(_ operationID: UUID?) -> TunnelResourceStatus {
        .init(phase: .failed, message: "VPN 保持连接。可用内存不足，已暂停更新资源。", operationID: operationID)
    }

    private func resourceMemoryBudget(generation: UInt64, operationID: UUID? = nil) throws -> Int? {
        let root = try Self.groupDirectory()
        let headroom = ResourceMemoryMonitor.available - ResourceMemoryMonitor.reserve
        guard headroom > 0 else {
            recordResourceFailure(Self.memoryPressureStatus(operationID))
            return nil
        }
        resourceMemoryMonitor = ResourceMemoryMonitor(root: root) { [weak self] in
            guard let self else { return }
            self.stateQueue.async {
                guard self.resourceGeneration == generation, self.resourceMemoryMonitor != nil else { return }
                self.resourceMemoryMonitor = nil
                self.resourcePreparation?.cancel()
                // Wait for an in-place update to report whether it already committed.
                if operationID != nil { return }
                self.resourceGeneration &+= 1
                self.resourcePreparation = nil
                self.startupResourceStatus = Self.memoryPressureStatus(nil)
            }
        }
        // Retain room for the provider's parsed indexes alongside the input bytes.
        return max(1, headroom / 2)
    }

    private func updateProvider(kind: ResourceKind, name: String, ticket: ActiveGoSession.Ticket, operationID: UUID) {
        resourceGeneration &+= 1
        let generation = resourceGeneration
        let budget: Int
        do {
            guard let available = try resourceMemoryBudget(generation: generation, operationID: operationID) else { return }
            budget = available
        } catch {
            resourceCompletionFailed(error, providerName: name, operationID: operationID)
            return
        }
        providerUpdateStatus = .init(phase: .preparing, message: "正在更新来源「\(name)」。", operationID: operationID)
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                let update = try ticket.session.makeProviderUpdate(kind: kind, name: name)
                update.setMemoryBudget(budget)
                let current = self.stateQueue.sync {
                    guard self.resourceGeneration == generation, self.sessions.isCurrent(ticket),
                          self.resourceMemoryMonitor != nil else { return false }
                    self.resourcePreparation = update
                    return true
                }
                guard current else { update.cancel(); throw CancellationError() }
                try update.updateProvider()
            }
            self.stateQueue.async {
                guard self.resourceGeneration == generation, self.sessions.isCurrent(ticket) else { return }
                let interruptedByPressure = self.resourceMemoryMonitor == nil
                self.resourcePreparation = nil
                self.resourceMemoryMonitor = nil
                switch result {
                case .success:
                    self.providerUpdateStatus = .init(phase: .ready, message: "来源「\(name)」已更新。", operationID: operationID)
                case .failure where interruptedByPressure:
                    self.providerUpdateStatus = Self.memoryPressureStatus(operationID)
                case .failure(let error):
                    self.resourceCompletionFailed(error, providerName: name, operationID: operationID)
                }
            }
        }
    }

    private func resourceCompletionFailed(_ error: Error, providerName: String? = nil, operationID: UUID? = nil) {
        resourceMemoryMonitor = nil
        let cause = TunnelStartupDiagnosticsStore.safeFailureMessage(error)
        let detail = cause.hasPrefix("隧道启动失败") ? "请检查节点连接或重试。" : cause
        let message = providerName.map { "来源「\($0)」更新失败。" } ?? "VPN 保持连接，资源补齐失败。"
        recordResourceFailure(.init(phase: .failed, message: message + detail, operationID: operationID))
    }

    private func recordResourceFailure(_ status: TunnelResourceStatus) {
        if status.operationID == nil { startupResourceStatus = status }
        else { providerUpdateStatus = status }
    }

    private static func encode(_ response: TunnelControlResponse) -> Data? {
        guard let data = try? JSONEncoder().encode(response), data.count <= 1_048_576 else {
            return try? JSONEncoder().encode(TunnelControlResponse(id: response.id, error: "The tunnel response exceeds the size limit."))
        }
        return data
    }

    private func readCounters(_ completion: @escaping @Sendable (Data?) -> Void) {
        let counters = countedFlow?.snapshot() ?? ["inputPackets": 0, "outputPackets": 0]
        let error = lastError
        lifecycle.readActiveRevision { revision in
            var response: [String: Any] = counters
            response["activeRevision"] = revision.map { $0 as Any } ?? NSNull()
            response["lastError"] = error.map { $0 as Any } ?? NSNull()
            completion(try? JSONSerialization.data(withJSONObject: response))
        }
    }

    private func makeApplication() -> RevisionApplication {
        let lifecycle = lifecycle
        let selectionOverrides = selectionOverrides
        return RevisionApplication(
            queue: stateQueue,
            load: { revision in
                let data = try Self.snapshotStore().loadForActivation(revision: revision)
                if let profileID = try RuntimeConfiguration.decode(data).profileID {
                    _ = try CoreStateStore(root: Self.groupDirectory().appendingPathComponent("CoreState", isDirectory: true)).directory(profileID: profileID)
                }
                return try selectionOverrides.configuration(data, revision: revision)
            },
            lastSuccessful: { try Self.snapshotStore().lastSuccessfulRevision() },
            start: { lifecycle.start(revision: $0, configuration: $1, completion: $2) },
            stop: { lifecycle.stop(completion: $0) },
            startedRevision: { _, completion in lifecycle.readActiveRevision(completion) }
        )
    }

    private func makeLifecycle() -> TunnelLifecycle {
        let flow = CountingPacketFlow(NetworkExtensionPacketFlow(packetFlow))
        countedFlow = flow
        // packetFlow reads cannot be cancelled, so all revisions share this pump.
        let pump = PacketPump(flow: flow, maximumPacketSize: 65_535)
        let sessions = sessions
        let selectionOverrides = selectionOverrides
        return TunnelLifecycle(
            prepare: { activation, completion in
                YAMLResourceActivation.prepare(activation, snapshotRoot: { try Self.snapshotDirectory() },
                                               stateRoot: { try Self.groupDirectory().appendingPathComponent("CoreState", isDirectory: true) },
                                               completion: { result in
                    do {
                        let prepared = try result.get()
                        try selectionOverrides.rememberPrepared(source: activation.revision, prepared: prepared.revision,
                                                               configuration: prepared.configuration)
                        completion(.success(prepared))
                    } catch { completion(.failure(error)) }
                })
            },
            installSettings: { [weak self] data, completion in
                guard let self else { completion(ProviderError.unavailable); return }
                do {
                    let configuration = try RuntimeConfiguration.decode(data)
                    let plan = try GoPacketSession.networkPlan(configuration: configuration)
                    let settings = plan.networkSettings()
                    self.setTunnelNetworkSettings(settings, completionHandler: completion)
                } catch { completion(error) }
            },
            clearSettings: { [weak self] completion in
                guard let self else { completion(ProviderError.unavailable); return }
                self.setTunnelNetworkSettings(nil, completionHandler: completion)
            },
            makeSession: { data in
                guard let configuration = String(data: data, encoding: .utf8) else { throw ProviderError.invalidConfiguration }
                let runtime = try RuntimeConfiguration.decode(data)
                let resourceRoot = try runtime.resources.map {
                    try ResourceBundleStore(root: Self.snapshotDirectory().appendingPathComponent("Resources", isDirectory: true)).directory(id: $0)
                }
                let stateRoot = try runtime.profileID.map {
                    try CoreStateStore(root: Self.groupDirectory().appendingPathComponent("CoreState", isDirectory: true)).directory(profileID: $0)
                }
                let cacheRoot = try? Self.groupDirectory().appendingPathComponent("IPQualityCache", isDirectory: true)
                let session = try GoPacketSession(configuration: configuration, resourceRoot: resourceRoot,
                                                  stateRoot: stateRoot, qualityCacheRoot: cacheRoot)
                sessions.install(session)
                return session
            },
            startPackets: { session, failure in pump.start(session: session) { failure($0) } },
            stopPackets: { completion in
                sessions.remove()?.cancelTests()
                pump.stop(completion: completion)
            },
            didStart: { revision in
                try Self.snapshotStore().markSuccessful(revision: revision)
                sessions.activate()
            },
            onFailure: { [weak self] error in
                guard let self, let error else { return }
                self.stateQueue.async {
                    _ = self.beginIntent()
                    self.canApply = false
                    self.lastError = error.localizedDescription
                    if let attemptID = self.startupAttemptID {
                        try? self.startupDiagnostics?.record(attemptID: attemptID, phase: .failed, error: error)
                    }
                    self.application.invalidate(error: error)
                    self.cancelTunnelWithError(error)
                }
            }
        )
    }

    private static func snapshotStore() throws -> SnapshotStore {
        SnapshotStore(root: try snapshotDirectory())
    }

    private static func snapshotDirectory() throws -> URL {
        try groupDirectory().appendingPathComponent("Snapshots", isDirectory: true)
    }

    private static func groupDirectory() throws -> URL {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.mashpolo.FlClashIOSProbe") else {
            throw ProviderError.appGroupUnavailable
        }
        return group
    }
}

private struct PendingControl {
    let action: TunnelControlRequest.Action
    let completion: @Sendable (Data?) -> Void
    var exitIPRequestID: Int64? = nil
}

private final class ActiveGoSession: @unchecked Sendable {
    struct Ticket: Sendable {
        let id: UUID
        let session: GoPacketSession
        let testGeneration: UInt64
    }

    private let lock = NSLock()
    private var ticket: Ticket?
    private var active = false
    private var testGeneration: UInt64 = 0

    func install(_ session: GoPacketSession) {
        lock.withLock {
            ticket = Ticket(id: UUID(), session: session, testGeneration: testGeneration)
            active = false
        }
    }

    func activate() { lock.withLock { active = true } }

    func current() -> Ticket? {
        lock.withLock {
            guard active, let ticket else { return nil }
            return Ticket(id: ticket.id, session: ticket.session, testGeneration: testGeneration)
        }
    }

    func isCurrent(_ value: Ticket) -> Bool { lock.withLock { active && ticket?.id == value.id } }
    func isCurrentTest(_ value: Ticket) -> Bool { lock.withLock { testGeneration == value.testGeneration } }
    func cancelTestIntent() { lock.withLock { testGeneration &+= 1 } }

    func remove() -> GoPacketSession? {
        lock.withLock {
            let session = ticket?.session
            ticket = nil
            active = false
            testGeneration &+= 1
            return session
        }
    }
}

private enum ProviderError: Error, LocalizedError {
    case missingRevision
    case appGroupUnavailable
    case invalidConfiguration
    case invalidRequest
    case unavailable

    var errorDescription: String? {
        switch self {
        case .missingRevision: return "A configuration revision is required."
        case .appGroupUnavailable: return "The shared configuration container is unavailable."
        case .invalidConfiguration: return "The configuration is not valid UTF-8."
        case .invalidRequest: return "The tunnel control request is incomplete."
        case .unavailable: return "The tunnel provider is unavailable."
        }
    }
}

private final class CountingPacketFlow: PacketFlow, @unchecked Sendable {
    private let wrapped: PacketFlow
    private let lock = NSLock()
    private var inputPackets = 0
    private var outputPackets = 0

    init(_ wrapped: PacketFlow) { self.wrapped = wrapped }

    func readPackets(completionHandler: @escaping @Sendable ([Data], [NSNumber]) -> Void) {
        wrapped.readPackets { packets, families in
            self.lock.lock()
            self.inputPackets += packets.count
            self.lock.unlock()
            completionHandler(packets, families)
        }
    }

    func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool {
        let accepted = wrapped.writePackets(packets, withProtocols: protocols)
        if accepted {
            lock.lock()
            outputPackets += packets.count
            lock.unlock()
        }
        return accepted
    }

    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return ["inputPackets": inputPackets, "outputPackets": outputPackets]
    }
}

extension PacketPumpError: TunnelRuntimeFailureDescribing {
    public var runtimeFailureMessage: String {
        switch self {
        case .invalidBatch: return "VPN 运行中断，系统返回的数据包和协议数量不一致。"
        case .invalidPacket: return "VPN 运行中断，数据包的长度或协议无效。"
        case .outputRejected: return "VPN 运行中断，系统拒绝写入隧道数据包。"
        }
    }
}
