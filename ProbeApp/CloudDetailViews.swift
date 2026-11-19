import SwiftUI

struct RemoteDeletionConflictView: View {
    @ObservedObject var model: LibraryModel
    let fileName: String
    let localHash: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(fileName).font(.headline)
                Text("同步目录已删除此配置，本地内容也有修改。请选择保留本地修改，或接受远端删除。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("保留本地修改，重新上传") { resolve(.local) }
                    .accessibilityIdentifier("sync-deletion-keep-local")
                Button("接受远端删除，备份并移除") { resolve(.remote) }
                    .accessibilityIdentifier("sync-deletion-accept-remote")
            } footer: {
                Text("处理前会重新检查文件版本。移除当前运行配置后，现有 VPN 会话继续运行，选择其他配置后再切换。")
            }
            .disabled(model.syncBusy)
            if model.syncBusy { ProgressView("正在处理…") }
            Section { Text(model.message).font(.footnote).textSelection(.enabled) }
        }
        .navigationTitle("删除冲突")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func resolve(_ choice: YAMLConflictChoice) {
        Task {
            await model.resolveRemoteDeletion(fileName, localHash: localHash, choice: choice)
            if !model.hasBlockedSync(fileName) { dismiss() }
        }
    }
}

struct CloudFirstSyncView: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(model.syncDirectory?.lastPathComponent ?? "未选择文件夹", systemImage: "folder.fill")
                        .font(.headline).foregroundStyle(.blue)
                    if let directory = model.syncDirectory { Text(directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Section("本次将检查") {
                    LabeledContent("本地 YAML", value: "\(model.profiles.count) 个")
                    LabeledContent("目录中的 YAML", value: "开始时扫描")
                }
                Section {
                    Label("同名但内容不同的文件会提示冲突。", systemImage: "doc.on.doc")
                    Label("仅同步 YAML 内容，订阅地址与节点选择保存在本机。", systemImage: "lock")
                    Label("当前配置内容更新后自动生效；远端删除配置会先备份，本地有修改时提示冲突。", systemImage: "info.circle")
                }.font(.subheadline)
                Section {
                    Button {
                        Task { await model.synchronize(); dismiss() }
                    } label: { HStack { Spacer(); Text("确认开始同步").bold(); Spacer() } }
                        .disabled(model.syncBusy || model.busy || !model.syncEnabled || model.syncDirectory == nil)
                        .accessibilityIdentifier("confirmFirstCloudSync")
                }
            }
            .navigationTitle("首次同步确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

private struct CloudBackup: Identifiable, Sendable {
    let url: URL
    let modified: Date?
    let size: Int
    var id: String { url.path }
    var shortHash: String { String(url.deletingPathExtension().lastPathComponent.prefix(12)) }

    static func load(root: URL) throws -> [CloudBackup] {
        let state = root.appendingPathComponent("SyncState", isDirectory: true)
        guard FileManager.default.fileExists(atPath: state.path) else { return [] }
        try CoordinatedYAMLFiles.checkDirectory(state)
        let directories = try FileManager.default.contentsOfDirectory(at: state, includingPropertiesForKeys: [.isDirectoryKey])
        var results: [CloudBackup] = []
        for directory in directories {
            try CoordinatedYAMLFiles.checkDirectory(directory)
            let backups = directory.appendingPathComponent("backups", isDirectory: true)
            guard FileManager.default.fileExists(atPath: backups.path) else { continue }
            try CoordinatedYAMLFiles.checkDirectory(backups)
            let files = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            for file in files where file.pathExtension.lowercased() == "yaml" {
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                results.append(CloudBackup(url: file, modified: values.contentModificationDate, size: values.fileSize ?? 0))
            }
        }
        return results.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }
}

struct CloudBackupsView: View {
    @ObservedObject var model: LibraryModel
    @State private var backups: [CloudBackup] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("同步替换内容前会保存本机备份。备份按内容标识存储，恢复时会创建新配置，供你检查后手动使用。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("备份记录（\(backups.count)）") {
                ForEach(backups) { backup in
                    NavigationLink { CloudBackupDetailView(model: model, backup: backup) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(backup.modified?.formatted(date: .abbreviated, time: .shortened) ?? "时间未知")
                                Text(backup.shortHash).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(backup.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if loading { ProgressView("读取备份") }
                else if backups.isEmpty { ContentUnavailableView("暂无同步备份", systemImage: "archivebox", description: Text("同步或处理冲突时，被替换的内容会保存在这里。")) }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("同步备份")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let root = model.root
        do { backups = try await Task.detached(priority: .utility) { try CloudBackup.load(root: root) }.value; error = nil }
        catch { self.error = "无法读取备份：\(error.localizedDescription)" }
    }
}

private struct CloudBackupDetailView: View {
    @ObservedObject var model: LibraryModel
    let backup: CloudBackup
    @State private var content: String?
    @State private var preview = "正在读取…"
    @State private var name = ""
    @State private var confirming = false
    @State private var restored = false
    @State private var error: String?

    var body: some View {
        List {
            Section("备份") {
                LabeledContent("保存时间", value: backup.modified?.formatted() ?? "未知")
                LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(backup.size), countStyle: .file))
                Text(backup.url.deletingPathExtension().lastPathComponent).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("YAML 预览") { Text(preview).font(.caption.monospaced()).textSelection(.enabled) }
            Section("恢复为新配置") {
                TextField("配置名称", text: $name)
                Button("恢复为新配置", systemImage: "arrow.counterclockwise") { confirming = true }
                    .disabled(content == nil || model.busy || restored || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("restoreCloudBackup")
                Text("创建新的本地配置，原配置与当前连接保持不变。新文件也可能在下次自动同步时写入同步目录。")
                    .font(.footnote).foregroundStyle(.secondary)
                if restored { Label("已恢复，请到配置页面检查", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("备份详情")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("将此备份恢复为新配置？", isPresented: $confirming, titleVisibility: .visible) {
            Button("创建新配置") {
                guard let content else { return }
                Task {
                    restored = await model.importText(content, name: name)
                    if !restored { error = model.message }
                }
            }
        } message: { Text("不会覆盖已有文件，也不会自动切换 VPN。") }
        .task {
            name = "恢复的配置 \(backup.shortHash)"
            do {
                let url = backup.url
                let result = try await Task.detached(priority: .utility) {
                    guard let data = try CoordinatedYAMLFiles.readBytes(url) else { throw ProfileStoreError.notFound }
                    _ = try YAMLDocument.validate(data: data)
                    let text = String(decoding: data, as: UTF8.self)
                    let preview = String(decoding: data.prefix(16_384), as: UTF8.self)
                        + (data.count > 16_384 ? "\n…预览已截断，恢复将使用完整内容。" : "")
                    return (text, preview)
                }.value
                content = result.0
                preview = result.1
            } catch { self.error = error.localizedDescription; preview = "无法读取备份" }
        }
    }
}
