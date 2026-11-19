import Foundation
import SwiftUI

struct GeoResourcesView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel
    @State private var entries: [GeoResourceEntry] = []
    @State private var message = "正在读取配置资源…"
    @State private var status = GeoResourceStatus.loading
    @State private var loadGeneration: UInt64 = 0
    private let kinds: [(kind: ResourceKind, name: String, symbol: String)] = [
        (.geoIPDat, "GeoIP", "location.fill"), (.geoSiteDat, "GeoSite", "globe"),
        (.asnMMDB, "ASN MMDB", "externaldrive.fill"), (.geoIPMMDB, "GeoIP MMDB", "square.3.layers.3d"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(kinds, id: \.kind.rawValue) { item in
                    NavigationLink {
                        GeoResourceDetailView(name: item.name, entry: entries.first { $0.kind == item.kind }, status: status, message: message)
                    } label: {
                        ClientRow(title: item.name, symbol: item.symbol,
                                  detail: status == .ready ? entries.first { $0.kind == item.kind }.map { formatStorageBytes(Int64($0.size)) } ?? "未包含" : status.rawValue,
                                  color: .green)
                    }
                }
            } header: {
                Text("所选配置已准备的资源")
            } footer: {
                Text(message)
            }
            Section {
                LabeledContent("当前选中配置", value: library.selectedProfile?.displayName ?? "未选择")
                Button {
                    Task {
                        await library.updateResources(using: model)
                        await load()
                    }
                } label: {
                    Label("更新资源", systemImage: "arrow.clockwise")
                }
                .disabled(library.selectedProfile == nil || library.busy || status == .loading)
                .accessibilityIdentifier("geo-update-resources")
                NavigationLink { ProfileLibraryView(model: library, probe: model) } label: {
                    Label("管理配置和资源来源", systemImage: "doc.text")
                }
            } header: {
                Text("资源更新")
            } footer: {
                Text("按所选配置中的来源更新资源。已连接时会自动重连并生效；未连接时在下次连接中使用。")
            }
            Section {
                Text(library.message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .navigationTitle("Geo 资源").navigationBarTitleDisplayMode(.inline)
        .task(id: [library.selectedID, model.pendingRevision]) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        entries = []
        status = .loading
        message = "正在读取配置资源…"
        guard let profileID = library.selectedID, let revision = model.pendingRevision else {
            status = .notPrepared
            message = "选择配置后连接或更新资源，即可查看。"
            return
        }
        do {
            let root = try model.snapshotDirectory()
            let result = try await Task.detached(priority: .utility) {
                try GeoResourceEntry.load(root: root, revision: revision, profileID: profileID)
            }.value
            guard generation == loadGeneration, library.selectedID == profileID, model.pendingRevision == revision, !Task.isCancelled else { return }
            guard let result else {
                status = .notPrepared
                message = "当前配置尚未准备资源，请连接或更新资源。"
                return
            }
            entries = result
            status = .ready
            message = "显示所选配置最近准备的资源。资源按 YAML 的实际需要准备，未包含不表示配置有误。"
        } catch {
            guard generation == loadGeneration, library.selectedID == profileID, model.pendingRevision == revision, !Task.isCancelled else { return }
            entries = []
            status = .failed
            message = "无法读取资源：\(error.localizedDescription)"
        }
    }
}

private enum GeoResourceStatus: String {
    case loading = "正在读取"
    case notPrepared = "尚未准备"
    case ready = "已读取"
    case failed = "读取失败"
}

private struct GeoResourceDetailView: View {
    let name: String
    let entry: GeoResourceEntry?
    let status: GeoResourceStatus
    let message: String

    var body: some View {
        Form {
            Section {
                ClientRow(title: name, symbol: "globe.asia.australia.fill",
                          detail: status == .ready ? (entry == nil ? "未包含" : "已校验") : status.rawValue, color: .green)
            }
            if let entry {
                Section("文件") {
                    LabeledContent("大小", value: formatStorageBytes(Int64(entry.size)))
                    LabeledContent("类型", value: entry.kind.rawValue)
                    LabeledContent("校验", value: "SHA-256 通过")
                }
                Section("SHA-256") {
                    Text(entry.sha256).font(.caption.monospaced()).textSelection(.enabled)
                }
            } else {
                Section {
                    ClientNotice(title: status == .ready ? "配置未包含此资源" : status.rawValue,
                                 message: status == .ready ? "Geo 资源按配置中的规则与来源准备。可检查 YAML 后更新资源。" : message,
                                 symbol: "doc.text.magnifyingglass")
                }
            }
        }
        .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
    }
}

private struct GeoResourceEntry: Decodable, Sendable {
    let kind: ResourceKind
    let size: Int
    let sha256: String

    static func load(root: URL, revision: String, profileID: String) throws -> [Self]? {
        let configuration = try RuntimeConfiguration.decode(SnapshotStore(root: root).load(revision: revision))
        guard configuration.profileID == profileID else { return nil }
        guard let resourceID = configuration.resources else { return [] }
        let directory = try ResourceBundleStore(root: root.appendingPathComponent("Resources")).directory(id: resourceID)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        return manifest.entries.filter { $0.kind.geodata != nil }
    }

    private struct Manifest: Decodable { let entries: [GeoResourceEntry] }
}

struct StorageSpaceView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel
    @State private var usage: StorageUsage?
    @State private var errorMessage: String?
    @State private var measurementGeneration: UInt64 = 0

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("本地文件总大小").font(.subheadline).foregroundStyle(.secondary)
                    if let usage {
                        Text(formatStorageBytes(usage.total)).font(.system(.largeTitle, design: .rounded, weight: .bold))
                        GeometryReader { geometry in
                            HStack(spacing: 2) {
                                ForEach(usage.items) { item in
                                    if item.bytes > 0 {
                                        Rectangle().fill(item.color)
                                            .frame(width: max(0, geometry.size.width - CGFloat(usage.items.filter { $0.bytes > 0 }.count - 1) * 2) * CGFloat(item.bytes) / CGFloat(max(1, usage.total)))
                                    }
                                }
                            }
                        }
                        .frame(height: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(.secondary)
                    } else {
                        ProgressView("正在统计…")
                    }
                }
                .padding(.vertical, 8)
            }
            if let usage {
                Section("使用情况") {
                    ForEach(usage.items) { item in
                        ClientRow(title: item.title, symbol: item.symbol, detail: formatStorageBytes(item.bytes), color: item.color)
                    }
                }
            }
            Section {
                NavigationLink { ProfileLibraryView(model: library, probe: model) } label: {
                    ClientRow(title: "管理配置文件", symbol: "doc.text")
                }
                NavigationLink { YAMLSyncView(model: library) } label: {
                    ClientRow(title: "管理同步与备份", symbol: "icloud", color: .cyan)
                }
                NavigationLink { GeoResourcesView(model: model, library: library) } label: {
                    ClientRow(title: "查看 Geo 资源", symbol: "globe", color: .green)
                }
            } header: {
                Text("管理")
            } footer: {
                Text("统计包括本地配置、资源、运行数据与同步数据，不含应用本身和云端目录。当前版本保留运行数据与资源，暂不提供自动清理。")
            }
        }
        .navigationTitle("存储空间").navigationBarTitleDisplayMode(.inline)
        .task { await measure() }
        .refreshable { await measure() }
    }

    private func measure() async {
        guard !Task.isCancelled else { return }
        measurementGeneration &+= 1
        let generation = measurementGeneration
        usage = nil
        errorMessage = nil
        do {
            let snapshots = try model.snapshotDirectory()
            let profiles = library.root
            let result = try await Task.detached(priority: .utility) { try StorageUsage.measure(profiles: profiles, snapshots: snapshots) }.value
            guard generation == measurementGeneration, !Task.isCancelled else { return }
            usage = result
            errorMessage = nil
        } catch {
            guard generation == measurementGeneration, !Task.isCancelled else { return }
            usage = nil
            errorMessage = "暂时无法统计文件大小：\(error.localizedDescription)"
        }
    }
}

private extension StorageUsage {
    var items: [StorageItem] {
        [
            StorageItem(id: 0, title: "配置文件", symbol: "doc.text", color: .blue, bytes: sizes[0]),
            StorageItem(id: 1, title: "资源副本", symbol: "square.3.layers.3d", color: .green, bytes: sizes[1]),
            StorageItem(id: 2, title: "运行数据与资源", symbol: "shield.lefthalf.filled", color: .orange, bytes: sizes[2]),
            StorageItem(id: 3, title: "同步数据与备份", symbol: "icloud", color: .cyan, bytes: sizes[3]),
            StorageItem(id: 4, title: "配置索引与偏好", symbol: "slider.horizontal.3", color: .purple, bytes: sizes[4]),
        ]
    }
}

private struct StorageItem: Identifiable {
    let id: Int
    let title: String
    let symbol: String
    let color: Color
    let bytes: Int64
}

private func formatStorageBytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}
