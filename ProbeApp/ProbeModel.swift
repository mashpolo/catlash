import Foundation
import Combine
import Network
import NetworkExtension
import UIKit

@MainActor
final class ProbeModel: ObservableObject {
    let runtime = RuntimeMonitor()
    let exitIP = ExitIPMonitor()
    private var exitIPObservation: AnyCancellable?
    private var routeGeneration: UInt64 = 0
    private var runtimeObservation: AnyCancellable?
    private var appStateObservers: [NSObjectProtocol] = []
    private var isForeground = false
    private var runtimeSuspended = false

    func setForeground(_ active: Bool) {
        let resumed = active && !isForeground
        let wasConnected = isConnected
        isForeground = active
        if active, Self.supportsVPN { refreshStatus() }
        else { updateRuntimeMonitoring() }
        if !active { exitIP.pause() }
        else if resumed, wasConnected, isConnected { refreshExitIP() }
    }

    func refreshExitIP(forceRefresh: Bool = false) {
        guard isForeground, isConnected else { return }
        let expectedRoute = routeGeneration
        Task { [weak self] in
            guard let self, isForeground, isConnected, expectedRoute == routeGeneration else { return }
            let lookup: ExitIPMonitor.Lookup = { [weak self] in
                guard let self else { throw CancellationError() }
                let response = try await self.control(.init(action: .exitIP, forceRefresh: forceRefresh))
                guard let result = response.exitIP else { throw ControlError.invalidReply }
                return result
            }
            if forceRefresh { await exitIP.refresh(using: lookup) }
            else { await exitIP.refreshIfNeeded(using: lookup) }
        }
    }

    private func exitRouteChanged() {
        routeGeneration &+= 1
        exitIP.stop()
        refreshExitIP()
    }

    private func updateRuntimeMonitoring() {
        guard isForeground, isConnected, !runtimeSuspended else { runtime.stop(); return }
        runtime.start { [weak self] request in
            guard let self else { throw ControlError.notConnected }
            return try await self.control(request)
        }
    }

    @Published private(set) var statusText = "未加载"
    @Published private(set) var isConnected = false
    @Published private(set) var connectedSince: Date?
    @Published private(set) var isStarting = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isProbing = false
    @Published private(set) var message = "选择配置后，点击连接即可启动 VPN。"
    @Published private(set) var connectionFailure: String?
    @Published private(set) var resourceStatus: TunnelResourceStatus?
    private var startupAttemptID: UUID?
    private var previousVPNStatus: NEVPNStatus = .invalid
    private var startupTask: Task<Void, Never>?
    @Published private(set) var pendingRevision: String?
    @Published private(set) var successfulRevision: String?
    @Published private(set) var activeRuntimeRevision: String?
    @Published private(set) var activeRuntimeScope: String?
    @Published private(set) var activeRuntimeProfileID: String?
    private var activeScopeGeneration: UInt64 = 0
    private var controlGeneration: UInt64 = 0
    var latencySessionGeneration: UInt64 { controlGeneration }
    private(set) var connectionGeneration: UInt64 = 0
    private var applicationGeneration: UInt64 = 0
    private var configurationApplicationTask: Task<TunnelControlResponse, Error>?
    private var revisionSaveTask: Task<Void, Error>?
    @Published private(set) var onDemandPolicy = OnDemandPolicy()
    @Published private(set) var onDemandSystemEnabled: Bool? = false
    @Published private(set) var onDemandBusy = false
    @Published private(set) var onDemandMessage = ""
    private var onDemandSaveTask: Task<Bool, Never>?

    @Published var useSOCKS5 = false
    @Published var server = ""
    @Published var port = "1080"
    @Published var username = ""
    @Published var password = ""

    static var supportsVPN: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    func snapshotDirectory() throws -> URL {
        #if targetEnvironment(simulator)
        let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SimulatorSnapshots", isDirectory: true)
        #else
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.mashpolo.FlClashIOSProbe") else {
            throw NSError(domain: "ProbeSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group 不可用，请检查主应用与扩展的签名和权限。"])
        }
        let root = container.appendingPathComponent("Snapshots", isDirectory: true)
        #endif
        return root
    }

    private func snapshotStore() throws -> SnapshotStore {
        SnapshotStore(root: try snapshotDirectory())
    }

    private var resourcePreparer: ProfileResourcePreparer?
    private var connectionSelections: [String: [String: String]] = [:]
    private let snapshotCommits = SnapshotCommitCoordinator()
    @Published private var snapshotPreparationCount = 0
    var isPreparingSnapshot: Bool { snapshotPreparationCount > 0 }

    func isCurrentSnapshotIntent(_ intent: SnapshotCommitCoordinator.Intent) -> Bool { snapshotCommits.isCurrent(intent) }

    func beginSnapshotIntent() -> SnapshotCommitCoordinator.Intent { snapshotCommits.begin() }
    func finishSnapshotIntent(_ intent: SnapshotCommitCoordinator.Intent) { snapshotCommits.finish(intent) }

    func prepareResources(yaml: Data, localFiles: [String: Data] = [:], scope: ProfileResourcePreparationScope = .connection, forceRefresh: Bool = false,
                          progress: (@Sendable (ProfileResourceProgress) async -> Void)? = nil) async throws -> String? {
        if resourcePreparer == nil {
            let root = try snapshotDirectory()
            resourcePreparer = ProfileResourcePreparer(
                bundleStore: ResourceBundleStore(root: root.appendingPathComponent("Resources", isDirectory: true)),
                cacheDirectory: root.appendingPathComponent("DownloaderCache", isDirectory: true)
            )
        }
        return try await resourcePreparer!.prepare(yaml: yaml, localFiles: localFiles, deferProxyDownloads: true,
                                                  scope: scope, forceRefresh: forceRefresh, progress: progress)
    }

    @discardableResult
    func stageYAML(_ data: Data, selections: [String: String], resourceBundleID: String? = nil, profileID: String? = nil,
                   snapshotIntent: SnapshotCommitCoordinator.Intent? = nil,
                   shouldCommit: @MainActor () -> Bool = { true }) async throws -> String {
        snapshotPreparationCount += 1
        defer { snapshotPreparationCount -= 1 }
        try Task.checkCancellation()
        let intent = snapshotIntent ?? beginSnapshotIntent()
        defer { if snapshotIntent == nil { finishSnapshotIntent(intent) } }
        guard snapshotCommits.isCurrent(intent), shouldCommit() else { throw CancellationError() }
        guard let yaml = String(data: data, encoding: .utf8) else { throw ProfileStoreError.invalidUTF8 }
        let root = try snapshotDirectory()
        let store = try snapshotStore()
        let storedSelections = try YAMLDocument.validate(data: data).selectionsForStorage(selections)
        let configuration = RuntimeConfiguration(outbound: .mihomo(yaml: yaml, selections: storedSelections), resources: resourceBundleID, profileID: profileID, allowDeferredResources: true)
        let prepared = try await Task.detached {
            if let resourceBundleID {
                _ = try ResourceBundleStore(root: root.appendingPathComponent("Resources", isDirectory: true)).directory(id: resourceBundleID)
            }
            return try store.prepare(configuration: configuration)
        }.value
        try Task.checkCancellation()
        guard shouldCommit() else { throw CancellationError() }
        let revision = try snapshotCommits.commit(prepared, to: store, intent: intent)
        connectionSelections[revision] = selections
        try await refreshSnapshots(store: store, loadEditor: false)
        if snapshotCommits.isCurrent(intent) {
            message = "配置已准备，等待连接验证。"
        }
        return revision
    }

    func control(_ request: TunnelControlRequest) async throws -> TunnelControlResponse {
        if request.action == .delay { try (request.delaySettings ?? ProxyDelaySettings()).validate() }
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected else { throw ControlError.notConnected }
        let expectedRoute = routeGeneration
        if request.action == .applyRevision { controlGeneration &+= 1 }
        let expectedIntent = intent
        let expectedGeneration = controlGeneration
        let requiresCurrentSession = request.action == .setMode || request.action == .catalog || request.action == .exitIP || request.action == .delay || request.action == .runtimeSnapshot || request.action == .closeConnection || request.action == .closeAllConnections || request.action == .clearDNSCache || request.action == .refreshResources || request.action == .effectiveConfiguration || request.action == .providerCatalog || request.action == .refreshProvider
        let isCurrent = {
            expectedIntent == self.intent && expectedGeneration == self.controlGeneration &&
                self.manager?.connection === session && session.status == .connected &&
                (request.action != .exitIP || expectedRoute == self.routeGeneration)
        }
        let response: TunnelControlResponse
        do {
            response = try await ControlRead().read(request: request, send: { data, reply in
                try session.sendProviderMessage(data, responseHandler: reply)
            }, cancel: {
                guard request.action == .exitIP,
                      let data = try? JSONEncoder().encode(TunnelControlRequest(action: .cancelExitIP, cancellingRequestID: request.id)) else { return }
                try? session.sendProviderMessage(data, responseHandler: { _ in })
            })
        } catch {
            if requiresCurrentSession, !isCurrent() { throw CancellationError() }
            throw error
        }
        if requiresCurrentSession, !isCurrent() { throw CancellationError() }
        if isConnected, isCurrent(), request.action != .refreshProvider, request.action != .providerCatalog {
            resourceStatus = response.resourceStatus
        }
        if let revision = response.activeRevision, isConnected, expectedIntent == intent,
           expectedGeneration == controlGeneration, manager?.connection === session {
            let changedRevision = activeRuntimeRevision.map { $0 != revision } ?? false
            readActiveScope(revision: revision)
            if changedRevision || (response.error == nil && (request.action == .select || request.action == .setMode)) {
                exitRouteChanged()
            }
        }
        return response
    }

    func retryResources() async {
        guard isConnected else { return }
        let expectedIntent = intent
        let expectedGeneration = controlGeneration
        let session = manager?.connection
        resourceStatus = .init(phase: .preparing, message: "正在重试配置资源…")
        do {
            let response = try await control(.init(action: .refreshResources))
            if response.error != nil { throw ControlError.invalidReply }
        } catch is CancellationError {
        } catch {
            guard isConnected, intent == expectedIntent, controlGeneration == expectedGeneration,
                  manager?.connection === session else { return }
            resourceStatus = .init(phase: .failed, message: "资源更新失败，请重试。")
        }
    }

    func applyConfiguration(revision: String) async throws -> TunnelControlResponse {
        applicationGeneration &+= 1
        let application = applicationGeneration
        let connection = connectionGeneration
        // Once sent, the extension may finish applying even if the caller moves
        // on. Keep its response and system configuration in the same owner.
        let task = Task { try await self.performConfigurationApplication(revision: revision, application: application, connection: connection) }
        configurationApplicationTask = task
        defer { if applicationGeneration == application { configurationApplicationTask = nil } }
        return try await task.value
    }

    private func performConfigurationApplication(revision: String, application: UInt64, connection: UInt64) async throws -> TunnelControlResponse {
        guard connection == connectionGeneration, application == applicationGeneration, isConnected else { throw CancellationError() }
        let response = try await control(.init(action: .applyRevision, revision: revision, selections: connectionSelections[revision]))
        _ = await onDemandSaveTask?.value
        try Task.checkCancellation()
        guard connection == connectionGeneration, application == applicationGeneration, isConnected else { throw CancellationError() }
        if let active = response.activeRevision {
            let previousSave = revisionSaveTask
            let save = Task { @MainActor in
                _ = try? await previousSave?.value
                guard connection == self.connectionGeneration, application == self.applicationGeneration, self.isConnected,
                      let manager = self.manager,
                      let configuration = manager.protocolConfiguration?.copy() as? NETunnelProviderProtocol else { throw CancellationError() }
                var values = configuration.providerConfiguration ?? [:]
                values["revision"] = active
                configuration.providerConfiguration = values
                manager.protocolConfiguration = configuration
                try await manager.saveToPreferences()
            }
            revisionSaveTask = save
            try await save.value
        }
        try Task.checkCancellation()
        guard connection == connectionGeneration, application == applicationGeneration, isConnected else { throw CancellationError() }
        try await refreshSnapshots(store: snapshotStore(), loadEditor: false)
        return response
    }

    func measureDelay(node: String, settings: ProxyDelaySettings, generation: UInt64, revision: String?) async throws -> Int64 {
        guard isConnected, controlGeneration == generation, activeRuntimeRevision == revision else { throw CancellationError() }
        let response = try await control(.init(action: .delay, node: node, delaySettings: settings))
        guard isConnected, controlGeneration == generation, activeRuntimeRevision == revision,
              response.activeRevision == revision else { throw CancellationError() }
        if let failure = response.delayFailure { throw failure }
        guard let delay = response.delayMilliseconds else { throw ProxyDelayFailure.failed }
        return delay
    }

    func runtimeConfiguration(revision: String) async throws -> RuntimeConfiguration {
        let store = try snapshotStore()
        return try await Task.detached {
            try RuntimeConfiguration.decode(store.loadForActivation(revision: revision))
        }.value
    }

    private func readActiveScope(revision: String) {
        guard activeRuntimeRevision != revision else { return }
        activeScopeGeneration &+= 1
        let request = activeScopeGeneration
        activeRuntimeRevision = revision
        activeRuntimeScope = nil
        activeRuntimeProfileID = nil
        Task {
            do {
                let configuration = try await runtimeConfiguration(revision: revision)
                guard request == activeScopeGeneration, isConnected else { return }
                activeRuntimeProfileID = configuration.profileID
                switch configuration.outbound {
                case .mihomo: activeRuntimeScope = "YAML 配置 · 默认路由"
                case .direct: activeRuntimeScope = "基础连通性测试 · 仅 1.1.1.1"
                case .socks5: activeRuntimeScope = "SOCKS5 基础测试 · 仅 1.1.1.1"
                }
            } catch {
                guard request == activeScopeGeneration, isConnected else { return }
                activeRuntimeScope = "运行范围读取失败"
            }
        }
    }

    func startDiagnostic() {
        guard Self.supportsVPN, !isPreparingSnapshot, !isConnected, !isStarting, !isConnecting else { return }
        let intent = beginSnapshotIntent()
        snapshotPreparationCount += 1
        Task {
            var preparedForConnection = false
            do {
                let outbound: RuntimeConfiguration.Outbound
                if useSOCKS5 {
                    guard let port = Int(port) else {
                        throw NSError(domain: "ProbeSnapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "端口必须是 1 到 65535 的整数。"])
                    }
                    outbound = .socks5(server: server, port: port, username: username, password: password, udp: true)
                } else { outbound = .direct }
                let store = try snapshotStore()
                let configuration = RuntimeConfiguration(outbound: outbound)
                let prepared = try await Task.detached { try store.prepare(configuration: configuration) }.value
                try snapshotCommits.commit(prepared, to: store, intent: intent)
                try await refreshSnapshots(store: store, loadEditor: false)
                preparedForConnection = snapshotCommits.isCurrent(intent)
            } catch {
                if snapshotCommits.isCurrent(intent) { message = "诊断准备失败：\(error.localizedDescription)" }
            }
            snapshotPreparationCount -= 1
            finishSnapshotIntent(intent)
            if preparedForConnection { connect() }
        }
    }

    func reloadSnapshots() { Task { await loadSnapshotState() } }

    private func loadSnapshotState() async {
        do {
            try await refreshSnapshots(store: snapshotStore(), loadEditor: true)
        } catch { message = "读取运行数据失败：\(error.localizedDescription)" }
    }

    private var snapshotReadGeneration: UInt64 = 0

    private func refreshSnapshots(store: SnapshotStore, loadEditor: Bool) async throws {
        snapshotReadGeneration &+= 1
        let generation = snapshotReadGeneration
        let observation = snapshotCommits.observe()
        let state = try await Task.detached {
            let pending = try store.pendingRevision()
            let successful = try store.lastSuccessfulRevision()
            let configuration = try loadEditor ? pending.map { try RuntimeConfiguration.decode(store.load(revision: $0)) } : nil
            let adoption = try store.prepareSuccessfulResourceAdoption()
            return (pending, successful, configuration, adoption)
        }.value
        guard generation == snapshotReadGeneration else { return }
        let adopted = try state.3.map { try snapshotCommits.adopt($0, to: store, observation: observation) } ?? false
        if adopted, let source = state.0, let prepared = state.1, let selections = connectionSelections[source] {
            connectionSelections[prepared] = selections
        }
        pendingRevision = adopted ? state.1 : state.0
        successfulRevision = state.1
        guard let configuration = state.2 else { return }
        switch configuration.outbound {
        case .mihomo:
            useSOCKS5 = false
        case .direct:
            useSOCKS5 = false
            server = ""; port = "1080"; username = ""; password = ""
        case .socks5(let host, let number, let user, let secret, _):
            useSOCKS5 = true
            server = host; port = String(number); username = user; password = secret
        }
    }

    private var manager: NETunnelProviderManager? {
        didSet {
            if oldValue?.connection.connectedDate != manager?.connection.connectedDate ||
                oldValue?.connection.status != manager?.connection.status { connectionGeneration &+= 1 }
        }
    }
    private var intent: UInt64 = 0 {
        didSet { if oldValue != intent { connectionGeneration &+= 1 } }
    }
    private var observer: NSObjectProtocol?
    private var dnsProbe: DNSProbe?
    private var probeGeneration: UInt64 = 0
    private let providerID = "com.mashpolo.FlClashIOSProbe.PacketTunnel"

    init() {
        isForeground = UIApplication.shared.applicationState == .active
        appStateObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setForeground(true) }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setForeground(false) }
            },
        ]
        runtimeObservation = runtime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        exitIPObservation = exitIP.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        for observer in appStateObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func restore() async {
        isForeground = UIApplication.shared.applicationState == .active
        await loadSnapshotState()
        guard Self.supportsVPN else {
            statusText = "模拟器：仅配置测试"
            await loadOnDemandPolicy()
            return
        }
        let request = intent
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard request == intent else { return }
            manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }
            if let manager {
                onDemandSystemEnabled = manager.isOnDemandEnabled
                do { onDemandPolicy = try savedOnDemandPolicy(manager, fallback: onDemandStore().load()) }
                catch { onDemandMessage = "读取按需规则失败：\(error.localizedDescription)" }
                let last = await startupDiagnostic()
                guard request == intent else { return }
                if startupAttemptID == nil, !isStarting, let last {
                    startupAttemptID = last.attemptID
                    if manager.connection.status == .disconnected {
                        await reportDisconnect(attemptID: last.attemptID, request: request)
                    }
                }
            }
            refreshStatus()
        } catch {
            message = "读取 VPN 配置失败：\(error.localizedDescription)"
        }
    }

    func connect() {
        guard Self.supportsVPN, !isPreparingSnapshot else { return }
        guard !onDemandBusy else { message = "请等待按需连接设置保存完成后再连接。"; return }
        runtimeSuspended = false
        runtime.stop(clear: true)
        intent &+= 1
        let request = intent
        let attemptID = UUID()
        startupAttemptID = attemptID
        startupTask?.cancel()
        connectionFailure = nil
        message = "正在保存系统 VPN 配置…"
        isStarting = true
        Task {
            do {
                _ = try? await revisionSaveTask?.value
                if manager == nil { await restore() }
                guard request == intent else { return }
                let store = try snapshotStore()
                try await refreshSnapshots(store: store, loadEditor: false)
                guard let revision = try await Task.detached(operation: { try store.pendingRevision() }).value else {
                    throw NSError(domain: "ProbeSnapshot", code: 3, userInfo: [NSLocalizedDescriptionKey: "配置尚未准备完成，请返回首页重新连接。"])
                }
                guard request == intent else { return }
                let selected = manager ?? NETunnelProviderManager()
                let configuration = (selected.protocolConfiguration?.copy() as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
                configuration.providerBundleIdentifier = providerID
                configuration.serverAddress = "Catlash"
                var providerValues = configuration.providerConfiguration ?? [:]
                providerValues["revision"] = revision
                configuration.providerConfiguration = providerValues
                selected.protocolConfiguration = configuration
                selected.localizedDescription = "Catlash"
                selected.isEnabled = true
                manager = selected
                try await selected.saveToPreferences()
                try await selected.loadFromPreferences()
                guard request == intent else { return }
                var options: [String: NSObject] = ["revision": revision as NSString, "attemptID": attemptID.uuidString as NSString]
                if let selections = connectionSelections[revision] {
                    let data = try JSONEncoder().encode(selections)
                    _ = try RuntimeSelectionOverrides.decode(data)
                    options["selections"] = data as NSData
                }
                try selected.connection.startVPNTunnel(options: options)
                message = "系统 VPN 正在启动，Mihomo 正在加载所选配置…"
                monitorStartup(attemptID: attemptID, request: request)
            } catch {
                guard request == intent else { return }
                message = "启动失败：\(error.localizedDescription)"
                connectionFailure = message
            }
            guard request == intent else { return }
            isStarting = false
            refreshStatus()
        }
    }

    func beginConnectionPreparation() {
        connectionFailure = nil
        message = "正在准备所选配置…"
    }

    func preparationFailed(_ reason: String) {
        connectionFailure = reason
        message = "配置准备失败，尚未启动系统 VPN。"
    }

    private func startupDiagnostic() async -> TunnelStartupDiagnostic? {
        guard let root = try? snapshotDirectory().deletingLastPathComponent() else { return nil }
        return try? await Task.detached { try TunnelStartupDiagnosticsStore(root: root).load() }.value
    }

    private func monitorStartup(attemptID: UUID, request: UInt64) {
        startupTask = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(90))
            while !Task.isCancelled {
                guard let self, self.intent == request, self.startupAttemptID == attemptID else { return }
                if self.isConnected { return }
                let diagnostic = await self.startupDiagnostic()
                guard self.intent == request, self.startupAttemptID == attemptID,
                      !Task.isCancelled, !self.isConnected else { return }
                if let diagnostic, diagnostic.attemptID == attemptID {
                    if diagnostic.phase == .failed {
                        self.connectionFailure = diagnostic.message
                        self.message = diagnostic.message
                        return
                    }
                    if diagnostic.phase == .preparing || diagnostic.phase == .starting { self.message = diagnostic.message }
                }
                if ContinuousClock.now >= deadline {
                    self.disconnect()
                    self.connectionFailure = "连接超时，已停止此次连接。请检查资源下载与节点连通性。"
                    self.message = self.connectionFailure!
                    return
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private func reportDisconnect(attemptID: UUID, request: UInt64) async {
        let diagnostic = await startupDiagnostic()
        guard request == intent, startupAttemptID == attemptID, !isConnected, !isConnecting else { return }
        let last = diagnostic.flatMap { $0.attemptID == attemptID ? $0 : nil }
        if let last, last.phase == .stopped || last.phase == .failed {
            connectionFailure = last.disconnectMessage
            message = last.message
        } else if let connection = manager?.connection {
            let error: Error? = await withCheckedContinuation { continuation in
                connection.fetchLastDisconnectError { continuation.resume(returning: $0) }
            }
            guard request == intent, startupAttemptID == attemptID, !isConnected, !isConnecting else { return }
            if let error {
                let reason = last?.phase == .connected
                    ? TunnelStartupDiagnosticsStore.safeRuntimeFailureMessage(error)
                    : TunnelStartupDiagnosticsStore.safeFailureMessage(error)
                connectionFailure = reason
                message = reason
            }
        }
        startupTask?.cancel()
        startupTask = nil
    }

    func disconnect() {
        guard let saving = onDemandSaveTask else { performDisconnect(); return }
        intent &+= 1
        let request = intent
        Task {
            _ = await saving.value
            guard request == intent else { return }
            performDisconnect()
        }
    }

    private func performDisconnect() {
        resourceStatus = nil
        startupTask?.cancel()
        startupTask = nil
        startupAttemptID = nil
        let snapshotIntent = beginSnapshotIntent()
        finishSnapshotIntent(snapshotIntent)
        intent &+= 1
        isStarting = false
        cancelProbe()
        runtimeSuspended = true
        runtime.stop()
        exitIP.stop()
        manager?.connection.stopVPNTunnel()
        message = "VPN 已断开。"
        refreshStatus()
    }

    private func onDemandStore() throws -> OnDemandPolicyStore {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ClientSettings", isDirectory: true)
        return OnDemandPolicyStore(root: root)
    }

    func loadOnDemandPolicy() async {
        guard !onDemandBusy, !isStarting else { return }
        onDemandBusy = true
        defer { onDemandBusy = false }
        let request = intent
        do {
            var saved = try onDemandStore().load()
            if Self.supportsVPN {
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                guard request == intent else { return }
                let selected = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }
                if let selected {
                    manager = selected
                    saved = try savedOnDemandPolicy(selected, fallback: saved)
                    onDemandSystemEnabled = selected.isOnDemandEnabled
                } else { onDemandSystemEnabled = false }
            } else { onDemandSystemEnabled = false }
            onDemandPolicy = saved
            onDemandMessage = Self.supportsVPN ? "已读取保存的规则。修改后需点击保存才会生效。" : "模拟器仅保存草稿，系统按需连接未启用。"
        } catch {
            onDemandSystemEnabled = nil
            onDemandMessage = "读取按需设置失败：\(error.localizedDescription)"
        }
    }

    func saveOnDemandPolicy(_ policy: OnDemandPolicy) async -> Bool {
        guard !onDemandBusy, !isStarting, !isConnecting else {
            onDemandMessage = "请等待当前连接或设置操作结束后重试。"
            return false
        }
        onDemandBusy = true
        defer { onDemandBusy = false; onDemandSaveTask = nil }
        let task = Task { await persistOnDemandPolicy(policy) }
        onDemandSaveTask = task
        return await task.value
    }

    private func persistOnDemandPolicy(_ policy: OnDemandPolicy) async -> Bool {
        var selected: NETunnelProviderManager?
        do {
            _ = try? await revisionSaveTask?.value
            try policy.validate()
            let store = try onDemandStore()
            guard Self.supportsVPN else {
                try store.save(policy)
                onDemandPolicy = policy
                onDemandSystemEnabled = false
                onDemandMessage = "草稿已保存；模拟器不会安装按需规则或启动 VPN。"
                return true
            }
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            selected = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }
            if selected == nil, !policy.enabled {
                try store.save(policy)
                onDemandPolicy = policy
                onDemandSystemEnabled = false
                onDemandMessage = "规则已保存，系统按需连接未启用。"
                return true
            }
            let target = selected ?? NETunnelProviderManager()
            selected = target
            let configuration = (target.protocolConfiguration?.copy() as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            var values = configuration.providerConfiguration ?? [:]
            if policy.enabled, values["revision"] == nil {
                guard let revision = try snapshotStore().pendingRevision() else {
                    throw NSError(domain: "OnDemand", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先从首页连接一次，再启用按需连接。"])
                }
                values["revision"] = revision
            }
            values["onDemandPolicyJSON"] = String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
            configuration.providerConfiguration = values
            configuration.providerBundleIdentifier = providerID
            configuration.serverAddress = "Catlash"
            target.protocolConfiguration = configuration
            target.localizedDescription = "Catlash"
            target.isEnabled = policy.enabled || target.isEnabled
            target.onDemandRules = try policy.systemRules()
            target.isOnDemandEnabled = policy.enabled
            try await target.saveToPreferences()
            try await target.loadFromPreferences()
            manager = target
            onDemandPolicy = try savedOnDemandPolicy(target, fallback: policy)
            onDemandSystemEnabled = target.isOnDemandEnabled
            do { try store.save(onDemandPolicy) }
            catch {
                onDemandMessage = "系统规则已保存，本地副本保存失败：\(error.localizedDescription)"
                refreshStatus()
                return true
            }
            onDemandMessage = policy.enabled ? "按需规则已保存到系统；满足规则后由系统自动连接或断开。" : "已保存，系统按需连接已关闭。"
            refreshStatus()
            return true
        } catch {
            if let selected {
                do {
                    try await selected.loadFromPreferences()
                    manager = selected
                    onDemandPolicy = try savedOnDemandPolicy(selected, fallback: onDemandPolicy)
                    onDemandSystemEnabled = selected.isOnDemandEnabled
                } catch { onDemandSystemEnabled = nil }
            }
            onDemandMessage = "保存失败：\(error.localizedDescription)。请重新读取系统状态后确认。"
            return false
        }
    }

    private func savedOnDemandPolicy(_ manager: NETunnelProviderManager, fallback: OnDemandPolicy) throws -> OnDemandPolicy {
        var policy = fallback
        if let raw = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["onDemandPolicyJSON"] as? String {
            policy = try JSONDecoder().decode(OnDemandPolicy.self, from: Data(raw.utf8))
        }
        policy.enabled = manager.isOnDemandEnabled
        try policy.validate()
        return policy
    }

    func probe() {
        guard isConnected, !isProbing else { return }
        probeGeneration &+= 1
        let request = probeGeneration
        isProbing = true
        message = "正在读取扩展开始计数…"
        Task {
            let before = await readCounters()
            guard request == probeGeneration, isProbing else { return }
            message = "正在向 1.1.1.1 查询 example.com…"
            let probe = DNSProbe()
            dnsProbe = probe
            let result = await withCheckedContinuation { continuation in
                probe.start { continuation.resume(returning: $0) }
            }
            guard request == probeGeneration, isProbing else { return }
            dnsProbe = nil
            message = result + "\n正在读取扩展结束计数…"
            let after = await readCounters()
            guard request == probeGeneration, isProbing else { return }
            isProbing = false
            message = result + "\n" + counterDelta(before: before, after: after)
        }
    }

    private func cancelProbe() {
        probeGeneration &+= 1
        dnsProbe?.cancel()
        dnsProbe = nil
        if isProbing { message = "本次探测已取消，未确认流量经过扩展。" }
        isProbing = false
    }

    private func readCounters() async -> Result<PacketCounters, CounterReadError> {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected else { return .failure(.unavailable) }
        return await CounterRead().read { reply in
            try session.sendProviderMessage(Data("counters".utf8), responseHandler: reply)
        }
    }

    private func refreshStatus() {
        let status = manager?.connection.status ?? .invalid
        let wasDisconnecting = previousVPNStatus == .disconnecting
        previousVPNStatus = status
        let wasConnected = isConnected
        let wasConnecting = isConnecting
        let replacedConnection = wasConnected && status == .connected && connectedSince != manager?.connection.connectedDate
        if wasConnected && (status != .connected || replacedConnection) {
            resourceStatus = nil
            controlGeneration &+= 1
            connectionGeneration &+= 1
        }
        isConnected = status == .connected
        if isConnected, !wasConnected {
            startupTask?.cancel()
            startupTask = nil
            connectionFailure = nil
            message = "VPN 已连接。"
        }
        if status == .disconnected || status == .invalid { runtimeSuspended = false }
        isConnecting = status == .connecting || status == .reasserting
        connectedSince = isConnected ? manager?.connection.connectedDate : nil
        if isConnected {
            Task {
                do { try await refreshSnapshots(store: snapshotStore(), loadEditor: false) }
                catch { message = "读取运行状态失败：\(error.localizedDescription)" }
            }
        }
        if !isConnected, isProbing { cancelProbe() }
        if !isConnected {
            resourceStatus = nil
            activeScopeGeneration &+= 1
            activeRuntimeRevision = nil
            activeRuntimeScope = nil
            activeRuntimeProfileID = nil
        }
        updateRuntimeMonitoring()
        if !isConnected { exitIP.stop() }
        else if replacedConnection { exitRouteChanged() }
        else if !wasConnected { refreshExitIP() }
        switch status {
        case .invalid: statusText = "尚未配置"
        case .disconnected: statusText = "已断开"
        case .connecting: statusText = "连接中"
        case .connected: statusText = "已连接"
        case .reasserting: statusText = "重新连接中"
        case .disconnecting: statusText = "断开中"
        @unknown default: statusText = "未知"
        }
        if (wasConnecting || wasConnected || wasDisconnecting), (status == .disconnected || status == .invalid), let attemptID = startupAttemptID {
            let request = intent
            Task { await reportDisconnect(attemptID: attemptID, request: request) }
        }
    }
}

private struct PacketCounters: Decodable {
    let inputPackets: Int
    let outputPackets: Int
}

private enum CounterReadError: Error {
    case unavailable
    case timeout
    case invalidResponse
    case failed(String)

    var message: String {
        switch self {
        case .unavailable: "VPN 未连接"
        case .timeout: "扩展计数请求超时"
        case .invalidResponse: "扩展计数响应无效"
        case .failed(let description): description
        }
    }
}

private func counterDelta(
    before: Result<PacketCounters, CounterReadError>,
    after: Result<PacketCounters, CounterReadError>
) -> String {
    switch (before, after) {
    case (.success(let first), .success(let last)):
        let input = last.inputPackets - first.inputPackets
        let output = last.outputPackets - first.outputPackets
        guard input >= 0, output >= 0 else { return "扩展计数已重置，未确认本次流量经过扩展。" }
        let delta = "探测期间扩展包数增量：输入 \(input)，输出 \(output)。"
        return delta + (input > 0 && output > 0 ? "检测到双向数据包。" : "未确认本次流量双向经过扩展。")
    case (.failure(let error), _):
        return "开始计数不可用（\(error.message)），未确认本次流量经过扩展。"
    case (_, .failure(let error)):
        return "结束计数不可用（\(error.message)），未确认本次流量经过扩展。"
    }
}

@MainActor
private final class CounterRead {
    private let timeoutNanoseconds: UInt64
    private var completion: ((Result<PacketCounters, CounterReadError>) -> Void)?
    private var timeout: Task<Void, Never>?

    init(timeoutNanoseconds: UInt64 = 2_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func read(using send: (@escaping (Data?) -> Void) throws -> Void) async -> Result<PacketCounters, CounterReadError> {
        await withCheckedContinuation { continuation in
            completion = { continuation.resume(returning: $0) }
            timeout = Task {
                do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                catch { return }
                finish(.failure(.timeout))
            }
            do {
                try send { [weak self] data in
                    Task { @MainActor in
                        guard let self else { return }
                        guard let data,
                              let counters = try? JSONDecoder().decode(PacketCounters.self, from: data),
                              counters.inputPackets >= 0, counters.outputPackets >= 0 else {
                            self.finish(.failure(.invalidResponse))
                            return
                        }
                        self.finish(.success(counters))
                    }
                }
            } catch {
                finish(.failure(.failed(error.localizedDescription)))
            }
        }
    }

    private func finish(_ result: Result<PacketCounters, CounterReadError>) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel()
        timeout = nil
        completion(result)
    }
}

private final class DNSProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "phase0.dns.probe")
    private let connection = NWConnection(host: "1.1.1.1", port: 53, using: .udp)
    private var completion: ((String) -> Void)?
    private var timeout: DispatchWorkItem?
    private let transaction: UInt16 = .random(in: 0...UInt16.max)

    func start(completion: @escaping (String) -> Void) {
        queue.async { [self] in
            self.completion = completion
            let timeout = DispatchWorkItem { [weak self] in self?.finish("DNS 探测超时。") }
            self.timeout = timeout
            self.queue.asyncAfter(deadline: .now() + 8, execute: timeout)
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.send()
                case .failed(let error): self.finish("DNS 探测失败：\(error.localizedDescription)")
                default: break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }

    func cancel() { queue.async { self.finish("DNS 探测已取消。") } }

    private func send() {
        let query = Data([
            UInt8(transaction >> 8), UInt8(transaction & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
            7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0, 0, 1, 0, 1,
        ])
        connection.send(content: query, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { self.finish("DNS 发送失败：\(error.localizedDescription)"); return }
            self.connection.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let error { self.finish("DNS 接收失败：\(error.localizedDescription)"); return }
                guard let data, data.count >= 12,
                      data[0] == UInt8(self.transaction >> 8), data[1] == UInt8(self.transaction & 255),
                      data[2] & 0x80 != 0 else {
                    self.finish("收到不匹配的 DNS 响应。")
                    return
                }
                let answers = Int(data[6]) << 8 | Int(data[7])
                let code = data[3] & 0x0f
                self.finish("收到 DNS 响应：\(data.count) 字节，\(answers) 条答案，返回码 \(code)。")
            }
        })
    }

    private func finish(_ result: String) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel()
        timeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(result)
    }
}

private enum ControlError: LocalizedError {
    case notConnected, timeout, invalidReply, rejected(String)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "请先连接 VPN；节点检查不会自动启动内核。"
        case .timeout: return "扩展响应超时，请检查系统 VPN 状态。"
        case .invalidReply: return "扩展返回了无效响应。"
        case .rejected(let message): return message
        }
    }
}

@MainActor
private final class ControlRead {
    private var completion: ((Result<TunnelControlResponse, Error>) -> Void)?
    private var timeout: Task<Void, Never>?

    func read(request: TunnelControlRequest, send: (Data, @escaping (Data?) -> Void) throws -> Void,
              cancel: @escaping @MainActor () -> Void) async throws -> TunnelControlResponse {
        let settings = request.delaySettings ?? ProxyDelaySettings()
        if request.action == .delay { try settings.validate() }
        let duration = request.action == .exitIP ? 25.0 : request.action == .delay ? settings.clientTimeout : 15.0
        let data = try JSONEncoder().encode(request)
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = { continuation.resume(with: $0) }
                timeout = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) } catch { return }
                    cancel()
                    finish(.failure(request.action == .delay ? ProxyDelayFailure.timeout : ControlError.timeout))
                }
                do {
                    try send(data) { [weak self] data in
                        Task { @MainActor in
                            guard let self else { return }
                            guard let data, data.count <= 1024 * 1024,
                                  let response = try? JSONDecoder().decode(TunnelControlResponse.self, from: data),
                                  response.id == request.id else {
                                self.finish(.failure(ControlError.invalidReply))
                                return
                            }
                            if let error = response.error, request.action != .applyRevision { self.finish(.failure(ControlError.rejected(error))) }
                            else { self.finish(.success(response)) }
                        }
                    }
                } catch { finish(.failure(error)) }
            }
        } onCancel: {
            Task { @MainActor in
                cancel()
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func finish(_ result: Result<TunnelControlResponse, Error>) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel()
        timeout = nil
        completion(result)
    }
}
