import SwiftUI

@MainActor
private final class DiagnosticTask<Value: Sendable>: ObservableObject {
    @Published private(set) var result: Value?
    @Published private(set) var error: String?
    @Published private(set) var running = false
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    deinit { task?.cancel() }

    func run(_ operation: @escaping @Sendable () async throws -> Value) {
        cancel()
        let request = generation
        result = nil; error = nil; running = true
        task = Task { [weak self] in
            do {
                let value = try await operation()
                guard !Task.isCancelled, let self, request == self.generation else { return }
                self.result = value; self.running = false; self.task = nil
            } catch {
                guard !Task.isCancelled, let self, request == self.generation else { return }
                self.error = error.localizedDescription; self.running = false; self.task = nil
            }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel(); task = nil
        if running { error = "已取消" }
        running = false
    }
}

struct NetworkQualityView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel
    @AppStorage("diagnosticDownloadURL") private var downloadURL = ""
    @AppStorage("diagnosticUploadURL") private var uploadURL = ""
    @StateObject private var request = DiagnosticTask<HTTPQualityResult>()
    @Environment(\.scenePhase) private var scenePhase

    private var usesDefaultServer: Bool { downloadURL.isEmpty && uploadURL.isEmpty }

    var body: some View {
        Form {
            Section {
                LabeledContent("VPN 状态", value: model.statusText)
                Button(request.running ? "取消测试" : "开始测试") {
                    if request.running {
                        request.cancel()
                    } else {
                        let download = usesDefaultServer ? "https://mensura.cdn-apple.com/api/v1/gm/large" : downloadURL
                        let upload = usesDefaultServer ? "https://mensura.cdn-apple.com/api/v1/gm/slurp" : uploadURL
                        request.run { try await NetworkDiagnostics.quality(download: download, upload: upload) }
                    }
                }.accessibilityIdentifier("network-quality-start")
                if request.running { ProgressView("正在测量…") }
                if let error = request.error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("通过当前网络测量延迟、下载和上传，收发各最多 2 MiB。")
            }
            Section {
                DisclosureGroup {
                    TextField("HTTPS 下载地址", text: $downloadURL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("HTTPS 上传地址（POST）", text: $uploadURL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !usesDefaultServer {
                        Button("恢复默认服务器") {
                            downloadURL = ""
                            uploadURL = ""
                        }
                    }
                } label: {
                    LabeledContent("测速服务器", value: usesDefaultServer ? "Apple" : "自定义")
                }
                .disabled(request.running)
            }
            Section("HTTP 测量结果") {
                HStack {
                    ToolMetric(title: "下载", value: speed(request.result?.downloadBytesPerSecond), symbol: "arrow.down", color: .blue)
                    ToolMetric(title: "上传", value: speed(request.result?.uploadBytesPerSecond), symbol: "arrow.up", color: .cyan)
                }
                LabeledContent("平均请求延迟", value: milliseconds(request.result?.averageLatency))
                LabeledContent("相邻请求抖动", value: milliseconds(request.result?.jitter))
                LabeledContent("延迟请求失败率", value: request.result.map { String(format: "%.0f%%", $0.failurePercent) } ?? "未测量")
                if let errors = request.result?.errors, !errors.isEmpty {
                    Text(errors.joined(separator: "\n")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink { NodeLibraryView(model: library, probe: model) } label: {
                    ClientRow(title: "节点延迟", symbol: "point.3.connected.trianglepath.dotted")
                }
            }
        }
        .navigationTitle("网络质量").navigationBarTitleDisplayMode(.inline)
        .onDisappear { request.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { request.cancel() } }
    }

    private func speed(_ value: Double?) -> String {
        value.map { String(format: "%.2f Mbit/s", $0 * 8 / 1_000_000) } ?? "—"
    }
    private func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "未测量" }
}

struct DNSQueryView: View {
    @ObservedObject var model: ProbeModel
    @State private var domain = "example.com"
    @State private var recordType = DNSDiagnosticType.a
    @State private var server = "1.1.1.1"
    @State private var port = "53"
    @StateObject private var request = DiagnosticTask<DNSDiagnosticResult>()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("查询") {
                TextField("域名", text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("记录类型", selection: $recordType) {
                    ForEach(DNSDiagnosticType.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("DNS 服务器", text: $server).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("端口", text: $port).keyboardType(.numberPad)
            }.disabled(request.running)
            Section {
                LabeledContent("VPN 状态", value: model.statusText)
                Text("通过 UDP 查询指定服务器。系统按当前 VPN 路由发送，YAML DNS 劫持规则可能改变实际解析器。模拟器使用本机网络。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(request.running ? "取消查询" : "查询") {
                    if request.running { request.cancel() }
                    else {
                        let domain = domain, type = recordType, server = server, port = port
                        request.run {
                            guard let value = UInt16(port), value > 0 else { throw NetworkDiagnosticError.invalidInput("端口必须是 1–65535。") }
                            return try await NetworkDiagnostics.dns(domain: domain, type: type, server: server, port: value)
                        }
                    }
                }.accessibilityIdentifier("dns-query")
                if request.running { ProgressView("正在查询…") }
            }
            Section("查询结果") {
                if let error = request.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                else if let result = request.result {
                    LabeledContent("DNS 返回码", value: String(result.responseCode))
                    LabeledContent("回答数量", value: String(result.answerCount))
                    Text(result.addresses.isEmpty ? "没有此类型的地址记录。" : result.addresses.joined(separator: "\n"))
                        .font(.callout.monospaced()).textSelection(.enabled).accessibilityIdentifier("dns-result")
                } else { Text("尚未查询").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("DNS 查询").navigationBarTitleDisplayMode(.inline)
        .onDisappear { request.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { request.cancel() } }
    }
}

struct STUNView: View {
    @ObservedObject var model: ProbeModel
    @State private var server = "stun.cloudflare.com"
    @State private var port = "3478"
    @StateObject private var request = DiagnosticTask<STUNDiagnosticResult>()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("STUN 服务器") {
                TextField("服务器地址", text: $server).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("UDP 端口", text: $port).keyboardType(.numberPad)
            }.disabled(request.running)
            Section {
                LabeledContent("VPN 状态", value: model.statusText)
                Text("通过当前网络查询 UDP 映射地址和端口。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(request.running ? "取消检测" : "开始检测") {
                    if request.running { request.cancel() }
                    else {
                        let server = server, port = port
                        request.run {
                            guard let value = UInt16(port), value > 0 else { throw NetworkDiagnosticError.invalidInput("端口必须是 1–65535。") }
                            return try await NetworkDiagnostics.stun(server: server, port: value)
                        }
                    }
                }.accessibilityIdentifier("stun-start")
                if request.running { ProgressView("等待服务器响应…") }
                if let error = request.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("检测结果") {
                LabeledContent("UDP 可达性", value: request.result == nil ? "尚未确认" : "已收到有效响应")
                LabeledContent("映射地址", value: request.result?.address ?? "—")
                LabeledContent("映射端口", value: request.result.map { String($0.port) } ?? "—")
                Text("单次 Binding 响应只能确认服务器看到的映射地址，不能判定 NAT 映射或过滤类型。完整行为探测需要支持 RFC 5780 的服务端。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("STUN 与 NAT").navigationBarTitleDisplayMode(.inline)
        .onDisappear { request.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { request.cancel() } }
    }
}

struct ToolMetric: View {
    let title: String
    let value: String
    let symbol: String
    var color: Color = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(value).font(.title2.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}
