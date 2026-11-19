import SwiftUI
import UniformTypeIdentifiers

struct RuntimeHealthView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel

    var body: some View {
        DiagnosticView(model: model)
    }
}

struct ExternalResourcesView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var probe: ProbeModel
    @State private var associating: MissingProfileResource?
    @State private var removing: ProfileLinkedResource?

    var body: some View {
        List {
            RemoteResourcesSection(model: probe, library: model)
            Section {
                LabeledContent("当前选择", value: model.selectedProfile?.displayName ?? "未选择配置")
                Text("以下管理所选配置关联的本地资源。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let missing = model.missingResource, missing.profileID == model.selectedID {
                Section("需要关联文件") {
                    ClientRow(title: missing.name, symbol: "exclamationmark.triangle", detail: missing.path, color: .orange)
                    Button("选择对应资源文件") { associating = missing }
                        .accessibilityIdentifier("associateLocalResource")
                }
            }
            Section("本地资源") {
                if model.resourceFiles.isEmpty {
                    ClientNotice(title: "没有关联的资源", message: "如果 YAML 引用了本地文件，连接或更新资源时会提示选择缺失的文件。", symbol: "externaldrive")
                }
                ForEach(model.resourceFiles) { resource in
                    NavigationLink {
                        ResourceDetailView(resource: resource)
                    } label: {
                        ClientRow(title: resource.displayName, symbol: "doc.zipper", detail: ByteCountFormatter.string(fromByteCount: Int64(resource.size), countStyle: .file), color: .purple)
                    }
                    .swipeActions {
                        Button("解除关联", role: .destructive) { removing = resource }
                    }
                }
            }
            if !probe.isConnected {
                Section {
                    Button("准备本地资源", systemImage: "arrow.clockwise") {
                        Task { await model.stageSelected(using: probe, forceRefresh: true) }
                    }
                    .disabled(model.busy || model.selectedProfile?.validationStatus != .pendingCoreValidation)
                }
            }
            Section("结果") { Text(model.message).font(.callout).textSelection(.enabled) }
        }
        .navigationTitle("外部资源")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $associating) { LibraryResourceAssociationView(model: model, request: $0) }
        .confirmationDialog("解除当前配置的资源关联？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("解除关联", role: .destructive) {
                if let resource = removing { Task { await model.removeResource(resource) } }
                removing = nil
            }
        } message: {
            Text("正在使用的资源副本会保留。下次准备配置时可能需要重新选择文件。")
        }
    }
}

private struct ResourceDetailView: View {
    let resource: ProfileLinkedResource

    var body: some View {
        List {
            Section {
                ClientRow(title: resource.displayName, symbol: "doc.zipper", detail: "本机内容副本", color: .purple)
                LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(resource.size), countStyle: .file))
            }
            Section("配置引用路径") { Text(resource.path).font(.callout.monospaced()).textSelection(.enabled) }
            Section("SHA-256") { Text(resource.sha256).font(.caption.monospaced()).textSelection(.enabled) }
        }
        .navigationTitle("资源详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DiagnosticInboxView: View {
    @ObservedObject var model: ProbeModel
    @State private var reports: [ReportEntry] = []
    @State private var generating = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                ClientNotice(title: "手动诊断报告", message: "记录当前连接与内存状态。本次页面中的报告需导出保存；系统崩溃及性能报告尚未接入。", symbol: "tray")
                Button {
                    Task { await generate() }
                } label: {
                    HStack {
                        if generating { ProgressView() }
                        Label("生成当前诊断", systemImage: "plus.circle")
                    }
                }.disabled(generating)
                    .accessibilityIdentifier("generate-diagnostic-report")
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            Section("本次打开 · \(reports.count) 份报告") {
                if reports.isEmpty {
                    ContentUnavailableView("暂无报告", systemImage: "doc.text.magnifyingglass", description: Text("点击“生成当前诊断”，查看并导出真实运行状态。"))
                }
                ForEach(reports) { entry in
                    NavigationLink { DiagnosticReportView(report: entry.report) } label: {
                        ClientRow(title: "诊断报告", symbol: "doc.text", detail: entry.report.generatedAt.formatted(date: .omitted, time: .standard), color: .orange)
                    }.accessibilityIdentifier("diagnostic-report-\(entry.id)")
                }
                .onDelete { reports.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("诊断收件箱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !reports.isEmpty { EditButton() } }
    }

    private func generate() async {
        generating = true
        message = nil
        defer { generating = false }
        var memory: ProcessMemorySample?
        if model.isConnected {
            do { memory = try await model.control(.init(action: .metrics)).metrics }
            catch { message = "扩展内存未能读取，报告保留当前应用与连接状态。" }
        }
        reports.insert(ReportEntry(report: DiagnosticReport.current(model: model, memory: memory)), at: 0)
    }

    private struct ReportEntry: Identifiable {
        let id = UUID()
        let report: DiagnosticReport
    }
}

struct DiagnosticReportView: View {
    let report: DiagnosticReport
    @State private var document = DiagnosticDocument(data: Data())
    @State private var exporting = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                ClientRow(title: "诊断报告", symbol: "doc.text.magnifyingglass", detail: report.generatedAt.formatted(), color: .orange)
                LabeledContent("应用版本", value: report.appVersion)
                LabeledContent("系统版本", value: report.operatingSystem)
                LabeledContent("连接状态", value: connectionText)
            }
            Section("扩展内存") {
                if let memory = report.extensionMemory {
                    LabeledContent("Physical footprint", value: formatBytes(memory.physicalFootprintBytes))
                    LabeledContent("驻留内存", value: formatBytes(memory.residentBytes))
                    LabeledContent("采样时间", value: memory.sampledAt.formatted())
                } else { Text("本报告没有扩展内存采样").foregroundStyle(.secondary) }
            }
            Section {
                Button("导出报告", systemImage: "square.and.arrow.up") {
                    do { document = DiagnosticDocument(data: try report.encoded()); exporting = true }
                    catch { message = "无法生成导出文件。" }
                }.accessibilityIdentifier("export-diagnostic-report")
                if let message { Text(message).font(.footnote) }
            } footer: {
                Text("报告包含应用与系统版本、连接状态、内部诊断标识及内存采样，不包含配置原文或节点凭据。")
            }
        }
        .navigationTitle("报告详情")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "catlash-diagnostics") { result in
            switch result {
            case .success: message = "报告已导出。"
            case .failure: message = "报告未导出，请重试。"
            }
        }
    }

    private var connectionText: String {
        switch report.connection {
        case .connected: "已连接"
        case .connecting: "连接中"
        case .disconnected: "已断开"
        case .simulator: "模拟器"
        }
    }

    private func formatBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
}
