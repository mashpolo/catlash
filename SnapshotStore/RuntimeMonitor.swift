import Combine
import Foundation

@MainActor
final class RuntimeMonitor: ObservableObject {
    typealias Send = @MainActor (TunnelControlRequest) async throws -> TunnelControlResponse

    @Published private(set) var snapshot: RuntimeSnapshot?
    @Published private(set) var rate: RuntimeTrafficRate?
    @Published private(set) var isFresh = false
    @Published private(set) var isPolling = false
    @Published private(set) var error: String?
    @Published private(set) var actionMessage: String?
    @Published private(set) var closingConnections: Set<String> = []
    @Published private(set) var runningActions: Set<TunnelControlRequest.Action> = []
    private var tracker = RuntimeTrafficTracker()
    private var generation: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var send: Send?
    private let sleep: @Sendable () async throws -> Void

    init(sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }) {
        self.sleep = sleep
    }

    deinit { pollTask?.cancel() }

    func start(using send: @escaping Send) {
        guard pollTask == nil else { return }
        generation &+= 1
        let request = generation
        self.send = send
        isPolling = true
        error = nil
        actionMessage = nil
        let sleep = sleep
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(generation: request, using: send)
                do { try await sleep() }
                catch { return }
            }
        }
    }

    func stop(clear: Bool = false) {
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        send = nil
        isPolling = false
        isFresh = false
        rate = nil
        tracker.reset()
        closingConnections.removeAll()
        runningActions.removeAll()
        if clear { snapshot = nil; error = nil; actionMessage = nil }
    }

    func closeConnection(_ connection: RuntimeConnection) async {
        guard let send, isFresh, let snapshot,
              snapshot.connections.contains(where: { $0.id == connection.id && $0.endedAt == 0 }),
              !closingConnections.contains(connection.id) else { return }
        let request = generation
        let sessionID = snapshot.sessionID
        closingConnections.insert(connection.id)
        actionMessage = nil
        defer { if request == generation { closingConnections.remove(connection.id) } }
        do {
            _ = try await send(TunnelControlRequest(action: .closeConnection, connectionID: connection.id))
            guard request == generation, self.snapshot?.sessionID == sessionID else { return }
            actionMessage = "已请求关闭连接，列表将在下一次采样时更新。"
        } catch {
            guard request == generation, self.snapshot?.sessionID == sessionID else { return }
            actionMessage = "关闭连接失败：\(error.localizedDescription)"
        }
    }

    var isClosingAllConnections: Bool { runningActions.contains(.closeAllConnections) }
    var isClearingDNSCache: Bool { runningActions.contains(.clearDNSCache) }

    func closeAllConnections() async {
        await performSessionAction(.closeAllConnections, success: "已请求关闭本次会话的全部活动连接；之后新建的连接不受影响。")
    }

    func clearDNSCache() async {
        await performSessionAction(.clearDNSCache, success: "已清除内核解析缓存。查询历史和 Fake-IP 映射仍保留。")
    }

    private func performSessionAction(_ action: TunnelControlRequest.Action, success: String) async {
        guard let send, isFresh, let snapshot, !runningActions.contains(action) else { return }
        let request = generation
        let sessionID = snapshot.sessionID
        runningActions.insert(action)
        actionMessage = nil
        defer { if request == generation { runningActions.remove(action) } }
        do {
            let response = try await send(TunnelControlRequest(action: action, expectedSessionID: sessionID))
            guard request == generation, !Task.isCancelled, self.snapshot?.sessionID == sessionID else { return }
            guard let state = response.runtime else { throw RuntimeMonitorError.missingSnapshot }
            guard state.sessionID == sessionID else { return }
            actionMessage = success
        } catch is CancellationError {
        } catch {
            guard request == generation, !Task.isCancelled, self.snapshot?.sessionID == sessionID else { return }
            actionMessage = "操作失败：\(error.localizedDescription)"
        }
    }

    private func refresh(generation request: UInt64, using send: Send) async {
        do {
            let response = try await send(TunnelControlRequest(action: .runtimeSnapshot))
            guard request == generation, !Task.isCancelled else { return }
            guard let snapshot = response.runtime else { throw RuntimeMonitorError.missingSnapshot }
            if self.snapshot?.sessionID != snapshot.sessionID { actionMessage = nil }
            rate = tracker.sample(snapshot)
            self.snapshot = snapshot
            isFresh = true
            error = nil
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            isFresh = false
            rate = nil
            tracker.reset()
            self.error = error.localizedDescription
        }
    }

    var uploadRateText: String { rate.map { Self.rateText($0.uploadBytesPerSecond) } ?? "—" }
    var downloadRateText: String { rate.map { Self.rateText($0.downloadBytesPerSecond) } ?? "—" }
    var uploadTotalText: String { snapshot.map { Self.bytes($0.uploadTotal) } ?? "—" }
    var downloadTotalText: String { snapshot.map { Self.bytes($0.downloadTotal) } ?? "—" }

    var exportedLogs: String {
        (snapshot?.logs ?? []).map {
            "\(Self.date($0.time).formatted(.iso8601)) [\($0.level.uppercased())] \($0.message)"
        }.joined(separator: "\n")
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }

    private static func rateText(_ value: Double) -> String {
        let units = ["B/s", "KiB/s", "MiB/s", "GiB/s"]
        var amount = value
        var unit = 0
        while amount >= 1_024 && unit < units.count - 1 { amount /= 1_024; unit += 1 }
        return amount.formatted(.number.precision(.fractionLength(unit == 0 ? 0 : 1))) + " " + units[unit]
    }
}

private enum RuntimeMonitorError: LocalizedError {
    case missingSnapshot
    var errorDescription: String? { "扩展未返回运行数据，请确认应用与扩展使用同一版本。" }
}
