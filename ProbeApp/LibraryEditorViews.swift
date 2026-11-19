import SwiftUI
import UniformTypeIdentifiers

struct LibraryResourceAssociationView: View {
    @ObservedObject var model: LibraryModel
    let request: MissingProfileResource
    @State private var choosing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Text("资源名称：\(request.name)")
                Text(request.path).font(.caption.monospaced()).textSelection(.enabled)
                Text("请选择此资源对应的本地文件。应用仅复制本次选择的内容，不会按 YAML 中的路径直接读取磁盘。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("从“文件”选择资源") { choosing = true }.disabled(model.busy)
                if model.busy { ProgressView("保存资源副本…") }
                Text(model.message).textSelection(.enabled)
            }
            .navigationTitle("关联本地资源")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.data, .yaml, .plainText]) { result in
                switch result {
                case .success(let url):
                    Task {
                        await model.associateResource(url, request: request)
                        if model.missingResource == nil { dismiss() }
                    }
                case .failure: model.message = "未选择资源文件。"
                }
            }
        }
    }
}

struct LibraryEditorView: View {
    @ObservedObject var model: LibraryModel
    let profile: ProfileRecord?
    @Environment(\.dismiss) private var dismiss
    @State private var name = "新配置"
    @State private var text = ""
    @State private var ready = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if profile == nil { TextField("名称", text: $name) }
                Section("YAML 原文") {
                    TextEditor(text: $text).font(.system(.body, design: .monospaced))
                        .frame(minHeight: 440).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("yamlEditor")
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .navigationTitle(profile == nil ? "粘贴 YAML" : "编辑 YAML")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            let saved: Bool
                            if let profile { saved = await model.save(text, profile: profile) }
                            else { saved = await model.importText(text, name: name) }
                            if saved { dismiss() } else { error = model.message }
                        }
                    }.disabled(!ready || model.busy)
                }
            }
            .task {
                guard let profile else { ready = true; return }
                do {
                    let data = try await model.repository.data(id: profile.id)
                    text = await Task.detached { String(decoding: data, as: UTF8.self) }.value
                    ready = true
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

struct SubscriptionEntryView: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "订阅"
    @State private var address = ""
    @State private var showAddress = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("名称", text: $name) }
                Section("订阅链接") {
                    Group {
                        if showAddress { TextField("HTTP / HTTPS 订阅地址", text: $address) }
                        else { SecureField("HTTP / HTTPS 订阅地址", text: $address) }
                    }.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Toggle("显示链接", isOn: $showAddress)
                }
                Label("导入后先校验，再选择是否启用", systemImage: "info.circle")
                    .font(.subheadline).foregroundStyle(.blue)
                Text("地址仅保存在本机，不写入同步 YAML。下载完整且语法有效后才导入，最大 16 MiB。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("导入订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下载") {
                        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            error = "请输入名称与有效的 HTTP / HTTPS 地址。"
                            return
                        }
                        model.downloadSubscription(url: url, name: name)
                        dismiss()
                    }.disabled(model.downloading)
                }
            }
        }
    }
}

struct YAMLConflictView: View {
    @ObservedObject var model: LibraryModel
    let fileName: String
    @State private var conflict: YAMLConflict
    @State private var localPreview = "正在加载…"
    @State private var remotePreview = "正在加载…"
    @State private var diff = "正在计算…"
    @Environment(\.dismiss) private var dismiss

    init(model: LibraryModel, fileName: String, conflict: YAMLConflict) {
        self.model = model
        self.fileName = fileName
        _conflict = State(initialValue: conflict)
    }

    var body: some View {
        List {
            Section("本地版本") {
                Text(conflict.localModified?.formatted() ?? "修改时间未知")
                Text(conflict.localHash).font(.caption.monospaced()).textSelection(.enabled)
                Text(localPreview).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("同步目录版本") {
                Text(conflict.remoteModified?.formatted() ?? "修改时间未知")
                Text(conflict.remoteHash).font(.caption.monospaced()).textSelection(.enabled)
                Text(remotePreview).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("文本差异（− 本地 / + 同步目录）") {
                Text(diff).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section {
                Button("使用本地版本，覆盖同步目录") { resolve(.local) }
                Button("使用同步目录版本，覆盖本地") { resolve(.remote) }
                Button("稍后处理") { dismiss() }
                Text("选择时会再次比较两端哈希；文件发生变化时拒绝覆盖。被替换的内容会在本机保留备份。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.disabled(model.syncBusy)
            Section("结果") { Text(model.message) }
        }
        .navigationTitle("处理冲突")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            Text(fileName).font(.caption).foregroundStyle(.secondary).padding(8)
                .frame(maxWidth: .infinity).background(.regularMaterial)
        }
        .task {
            let displayedConflict = conflict
            let values = await Task.detached(priority: .utility) {
                (conflictPreview(displayedConflict.localData), conflictPreview(displayedConflict.remoteData), conflictDifference(displayedConflict))
            }.value
            localPreview = values.0; remotePreview = values.1; diff = values.2
        }
    }

    private func resolve(_ choice: YAMLConflictChoice) {
        Task {
            await model.resolve(fileName, conflict: conflict, choice: choice)
            if !model.hasBlockedSync(fileName) { dismiss() }
        }
    }
}

struct ProviderConflictView: View {
    let fileName: String
    let versions: [YAMLConflictVersion]
    @State private var previews: [String: String] = [:]

    var body: some View {
        List {
            Section {
                Text("文件提供方报告了多个未解决版本。已暂停该文件的自动写入；请在支持版本管理的文件提供方中处理，再回到这里重新同步。")
                Text("展示备份不代表冲突已解决。应用不会擅自将系统版本标记为已解决。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(versions, id: \.identifier) { version in
                Section(version.modificationDate?.formatted() ?? "时间未知") {
                    Text(version.identifier).font(.caption.monospaced())
                    Text(previews[version.identifier] ?? "正在加载…").font(.caption.monospaced()).textSelection(.enabled)
                    if let error = version.error { Text(error).foregroundStyle(.red) }
                    Text(version.backupURL == nil ? "此版本尚未完成本地备份" : "已保留本地备份").font(.caption)
                }
            }
        }
        .navigationTitle(fileName)
        .task {
            previews = await Task.detached(priority: .utility) {
                var result: [String: String] = [:]
                for version in versions { result[version.identifier] = version.data.map(conflictPreview) ?? "版本内容暂不可用" }
                return result
            }.value
        }
    }
}

private func conflictPreview(_ data: Data) -> String {
    let limit = 16 * 1024
    return String(decoding: data.prefix(limit), as: UTF8.self) + (data.count > limit ? "\n…预览已截断，仅显示前 16 KiB。" : "")
}

private func conflictDifference(_ conflict: YAMLConflict) -> String {
    let lhs = Array(String(decoding: conflict.localData.prefix(16 * 1024), as: UTF8.self).components(separatedBy: "\n").prefix(160))
    let rhs = Array(String(decoding: conflict.remoteData.prefix(16 * 1024), as: UTF8.self).components(separatedBy: "\n").prefix(160))
    let changes = rhs.difference(from: lhs).map { change in
        switch change {
        case .remove(let offset, let line, _): "− \(offset + 1): \(line)"
        case .insert(let offset, let line, _): "+ \(offset + 1): \(line)"
        }
    }
    let text = changes.isEmpty ? "展示范围内没有文本差异。" : changes.joined(separator: "\n")
    return text + "\n\n差异仅比较每端前 16 KiB、最多 160 行；完整内容以文件为准。"
}
