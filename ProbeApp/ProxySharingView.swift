import SwiftUI
import Darwin

struct ProxySharingView: View {
    @ObservedObject var model: ProbeModel
    @State private var status: ProxySharingStatus?
    @State private var listenAddress = "0.0.0.0"
    @State private var httpPort = "7890"
    @State private var socksPort = "7891"
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message = ""
    @State private var generation = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                LabeledContent("状态", value: model.isConnected ? (status.map { $0.enabled ? "共享中" : "未启动" } ?? "未读取") : "VPN 未连接")
                if let status, status.enabled {
                    LabeledContent("监听地址", value: status.listenAddress)
                    LabeledContent("HTTP 端口", value: String(status.httpPort))
                    LabeledContent("SOCKS5 端口", value: String(status.socksPort))
                    ForEach(localAddresses(), id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                }
            }
            Section("监听设置") {
                TextField("监听 IP", text: $listenAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("HTTP 端口", text: $httpPort).keyboardType(.numberPad)
                TextField("SOCKS5 端口", text: $socksPort).keyboardType(.numberPad)
            }
            Section("身份验证") {
                TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码", text: $password)
                Text("用户名和密码均必填；密码只用于本次启用，不保存到客户端偏好。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(status?.enabled == true ? "更新共享设置" : "启用共享") { Task { await configure(enabled: true) } }
                    .disabled(busy || !model.isConnected)
                Button("停止共享", role: .destructive) { Task { await configure(enabled: false) } }
                    .disabled(busy || !model.isConnected || status?.enabled != true)
                if busy { ProgressView() }
                if !message.isEmpty { Text(message).font(.footnote).textSelection(.enabled) }
            } footer: {
                Text("同一局域网设备使用此 iPhone 的 Wi-Fi IP 与对应端口连接。支持 HTTP、HTTPS CONNECT 和 SOCKS5 TCP，SOCKS5 UDP 不支持。共享连接使用当前内核路由，并计入连接列表与流量；断开 VPN 或切换运行配置后停止共享。")
            }
        }
        .navigationTitle("代理共享").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .task(id: model.runtime.snapshot?.sessionID) { await refresh() }
        .onChange(of: model.isConnected) { _, _ in Task { await refresh() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
            else { generation += 1 }
        }
        .onDisappear { generation += 1 }
    }

    private func refresh() async {
        generation += 1
        let ticket = generation
        status = nil
        guard model.isConnected else { return }
        do {
            let response = try await model.control(.init(action: .sharingStatus))
            guard ticket == generation, !Task.isCancelled else { return }
            status = response.sharing
        } catch {
            guard ticket == generation, !Task.isCancelled else { return }
            status = nil
            message = "读取共享状态失败：\(error.localizedDescription)"
        }
    }

    private func configure(enabled: Bool) async {
        guard !busy else { return }
        guard !enabled || (!username.isEmpty && !password.isEmpty && (1...65535).contains(Int(httpPort) ?? 0)
                           && (1...65535).contains(Int(socksPort) ?? 0) && httpPort != socksPort) else {
            message = "请填写用户名、密码及两个不同的 1–65535 端口。"
            return
        }
        busy = true
        generation += 1
        let ticket = generation
        defer { busy = false }
        do {
            let configuration = ProxySharingConfiguration(enabled: enabled, listenAddress: listenAddress,
                httpPort: Int(httpPort) ?? 7890, socksPort: Int(socksPort) ?? 7891, username: username, password: password)
            let response = try await model.control(.init(action: .configureSharing, sharingConfiguration: configuration))
            guard ticket == generation else { return }
            status = response.sharing
            password = ""
            message = status?.enabled == true ? "共享已启动。" : "共享已停止。"
        } catch {
            guard ticket == generation else { return }
            message = "共享设置失败：\(error.localizedDescription)"
            await refresh()
        }
    }

    private func localAddresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [String] = []
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == AF_INET,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  String(cString: entry.pointee.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append("Wi-Fi IP：" + String(cString: host))
            }
        }
        return result
    }
}
