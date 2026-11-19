import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticView: View {
    @ObservedObject var model: ProbeModel
    @State private var memory: ProcessMemorySample?
    @State private var message = "尚未采样"
    @State private var isSampling = false
    @State private var document = DiagnosticDocument(data: Data())
    @State private var isExporting = false

    var body: some View {
        Form {
            Section {
                ClientRow(title: model.statusText, symbol: model.isConnected ? "checkmark.shield.fill" : "shield", detail: "系统 VPN 状态", color: model.isConnected ? .green : .blue)
            }
            Section {
                HStack {
                    ToolMetric(title: "Physical footprint", value: memory.map { bytes($0.physicalFootprintBytes) } ?? "—", symbol: "memorychip", color: .purple)
                    ToolMetric(title: "驻留内存", value: memory.map { bytes($0.residentBytes) } ?? "—", symbol: "square.stack.3d.up", color: .cyan)
                }
                if let memory {
                    LabeledContent("Physical footprint", value: bytes(memory.physicalFootprintBytes))
                    LabeledContent("驻留内存", value: bytes(memory.residentBytes))
                    LabeledContent("采样时间", value: memory.sampledAt.formatted())
                }
                Text(message).font(.footnote)
                Button("采样扩展内存", systemImage: "arrow.clockwise") { Task { await sample() } }
                    .disabled(!model.isConnected || isSampling)
                if isSampling { ProgressView("正在采样") }
            } header: {
                Text("扩展内存")
            } footer: {
                Text("连接 VPN 后读取扩展当前内存。单次采样不代表历史峰值。")
            }
            Section("诊断文件") {
                Text("包含应用版本、系统版本、连接状态、内部版本标识及最近一次内存采样。")
                    .font(.footnote)
                Button("导出诊断 JSON") { export() }
            }
            Section("高级诊断") {
                NavigationLink { ConnectionView(model: model) } label: {
                    ClientRow(title: "基础连接诊断", symbol: "stethoscope", detail: "DIRECT / SOCKS5 与数据包验证")
                }.accessibilityIdentifier("basic-connection-diagnostics")
            }
        }
        .navigationTitle("运行状况")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $isExporting, document: document, contentType: .json,
                      defaultFilename: "catlash-diagnostics") { result in
            switch result {
            case .success: message = "诊断文件已导出"
            case .failure: message = "诊断文件导出失败"
            }
        }
    }

    private func sample() async {
        isSampling = true
        defer { isSampling = false }
        do {
            let response = try await model.control(TunnelControlRequest(action: .metrics))
            memory = response.metrics
            message = memory == nil ? "扩展未返回内存采样" : "已读取扩展进程的当前内存"
        } catch { message = "无法读取扩展内存，请确认 VPN 仍在连接" }
    }

    private func export() {
        let report = DiagnosticReport.current(model: model, memory: memory)
        do {
            document = DiagnosticDocument(data: try report.encoded())
            isExporting = true
        } catch { message = "无法生成诊断文件" }
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
}

extension DiagnosticReport {
    @MainActor
    static func current(model: ProbeModel, memory: ProcessMemorySample?) -> DiagnosticReport {
        let connection: Connection = !ProbeModel.supportsVPN ? .simulator
            : model.isConnected ? .connected : (model.isStarting || model.isConnecting) ? .connecting : .disconnected
        return DiagnosticReport(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                                connection: connection, pendingRevision: model.pendingRevision,
                                successfulRevision: model.successfulRevision, extensionMemory: memory)
    }
}

struct DiagnosticDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
