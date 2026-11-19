import SwiftUI

struct ProfileDetailView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var probe: ProbeModel
    let profile: ProfileRecord
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ProfileRecord?
    @State private var renaming = false
    @State private var deleting: ProfileRecord?
    @State private var name = ""
    @State private var operationError: String?

    private var current: ProfileRecord { model.profiles.first(where: { $0.id == profile.id }) ?? profile }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: current.sourceURL == nil ? "doc.text.fill" : "icloud.fill").font(.largeTitle).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(current.displayName).font(.title3.bold())
                        Text(model.selectedID == profile.id ? "已选择" : "本地配置").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
                LabeledContent("来源", value: current.sourceURL == nil ? "本地 YAML" : "订阅")
                if let overview = current.overview {
                    NavigationLink {
                        List(overview.proxyNames.indices, id: \.self) { index in
                            Text(overview.proxyNames[index])
                        }.navigationTitle("节点")
                    } label: { LabeledContent("节点", value: "\(overview.proxyNames.count)") }
                    .disabled(overview.proxyNames.isEmpty)
                    NavigationLink {
                        ProfileGroupsView(groups: overview.proxyGroups)
                    } label: { LabeledContent("策略组", value: "\(overview.proxyGroups.count)") }
                    .disabled(overview.proxyGroups.isEmpty)
                } else {
                    LabeledContent("节点", value: "—")
                    LabeledContent("策略组", value: "—")
                }
                LabeledContent("上次更新", value: current.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if current.validationStatus == .invalidYAML {
                Section {
                    Label("配置文件格式有误，请编辑后保存。", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            if let url = current.sourceURL {
                SubscriptionProfileSection(model: model, profile: current, url: url)
            }
            Section {
                Button("选择此配置", systemImage: "checkmark.circle") { Task { operationError = await model.select(profile.id) } }
                    .disabled(model.busy || model.selectedID == profile.id)
                Button("编辑 YAML", systemImage: "square.and.pencil") { editing = current }
                Button("重命名", systemImage: "pencil") { name = current.displayName; renaming = true }
                Button("复制配置", systemImage: "doc.on.doc") { Task { operationError = await model.duplicate(current) } }
                Button("仅删除本地", systemImage: "trash", role: .destructive) { deleting = current }
            }.disabled(model.busy)
            if let operationError {
                Section { Text(operationError).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .navigationTitle(current.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { record in LibraryEditorView(model: model, profile: record) }
        .alert("重命名", isPresented: $renaming) {
            TextField("配置名称", text: $name)
            Button("取消", role: .cancel) { }
            Button("保存") { Task { operationError = await model.rename(current, name: name) } }
        }
        .confirmationDialog("仅删除本地配置？云端文件会保留。", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { record in
            Button("删除本地", role: .destructive) {
                Task {
                    operationError = await model.delete(record)
                    if operationError == nil { dismiss() }
                }
            }
        }
    }
}

struct StrategyGroupsView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var probe: ProbeModel
    @State private var search = ""

    var body: some View {
        List {
            ForEach(model.nodeGroups(connected: probe.isConnected).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { group in
                NavigationLink {
                    StrategyGroupDetailView(model: model, probe: probe, groupName: group.name)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.3.layers.3d").font(.title2).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.name).font(.headline)
                            Text("当前：\(group.selected ?? "尚未选择")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(group.type).font(.caption).foregroundStyle(.blue)
                            Text("\(group.members.count) 个节点").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
            }
            if model.nodeGroups(connected: probe.isConnected).isEmpty {
                ContentUnavailableView("暂无策略组", systemImage: "square.3.layers.3d", description: Text("选择含策略组的配置后，返回查看。"))
            }
        }
        .navigationTitle("策略组")
        .searchable(text: $search, prompt: "搜索策略组")
    }
}

struct StrategyGroupDetailView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var probe: ProbeModel
    let groupName: String
    @State private var search = ""
    @State private var detail: NodeDetailDestination?

    var body: some View {
        List {
            if let group = model.nodeGroups(connected: probe.isConnected).first(where: { $0.name == groupName }) {
                let candidates = ProxyDelayPreferences.matching(group.members, search: search)
                Section {
                    LabeledContent("选择方式", value: group.type)
                    LabeledContent("当前节点", value: group.selected ?? "尚未选择")
                }
                Section("节点") {
                    if model.isTestingDelays {
                        Button("取消测速", systemImage: "stop.circle") {
                            Task { await model.cancelDelay(using: probe) }
                        }
                    } else {
                        Button(search.isEmpty ? "整组测速" : "测速搜索结果", systemImage: "gauge.with.dots.needle.50percent") {
                            Task { await model.testDelays(candidates, groupURL: group.testURL, using: probe) }
                        }.disabled(!probe.isConnected || candidates.isEmpty)
                            .accessibilityIdentifier("test-group-\(group.name)")
                    }
                    ForEach(model.visibleNodes(candidates, groupURL: group.testURL, connected: probe.isConnected), id: \.self) { node in
                        StrategyNodeRow(model: model, probe: probe, group: group, node: node, detail: $detail)
                    }
                }
            } else { Text("策略组已变更，请返回刷新。").foregroundStyle(.secondary) }
        }.navigationTitle(groupName).navigationBarTitleDisplayMode(.inline)
            .sheet(item: $detail) { destination in
                NavigationStack { NodeDetailView(model: model, probe: probe, groupName: destination.groupName, node: destination.node) }
            }
            .searchable(text: $search, prompt: "搜索节点")
            .toolbar { ProxyDelayDisplayMenu(model: model) }
    }
}

struct NodeDetailDestination: Hashable, Identifiable {
    let groupName: String
    let node: String
    var id: Self { self }
}

struct StrategyNodeRow: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var probe: ProbeModel
    let group: LibraryNodeGroup
    let node: String
    @Binding var detail: NodeDetailDestination?
    @AppStorage(NodeDisplaySettings.iconsKey) private var showIcons = false
    @AppStorage(NodeDisplaySettings.compactKey) private var compactRows = false

    private var selected: Bool { group.selected == node }
    private var measuredDelay: ProxyDelayResult? { model.delayResult(node, groupURL: group.testURL, connected: probe.isConnected) }

    var body: some View {
        HStack(spacing: 0) {
            if group.canSelect {
                Button { Task { await model.selectNode(node, group: group, using: probe) } } label: { memberLabel }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                    .accessibilityLabel(node)
                    .accessibilityIdentifier("node-\(group.name)-\(node)")
                    .accessibilityValue(selected ? "已选中" : "未选中")
            } else { memberLabel }
            Button { detail = NodeDetailDestination(groupName: group.name, node: node) } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看 \(node) 详情")
            .accessibilityIdentifier("node-info-\(group.name)-\(node)")
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 4))
    }

    private var memberLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 20)
                .opacity(selected ? 1 : 0)
                .accessibilityHidden(true)
            if showIcons {
                Image(systemName: "network").foregroundStyle(.secondary).frame(width: 24)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: compactRows ? 1 : 3) {
                Text(node).font(compactRows ? .subheadline : .body).lineLimit(1)
                Text(nodeProtocolLabel(model.nodeProtocol(node, connected: probe.isConnected)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.isTestingNode(node, groupURL: group.testURL) { ProgressView() }
            else if let delay = measuredDelay {
                Text(delay.text).font(.caption.monospacedDigit()).foregroundStyle(delay.displayColor)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compactRows ? 44 : 58, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension ProxyDelayResult {
    var displayColor: Color {
        switch self {
        case .measured(let value) where value < 200: return .green
        case .measured(let value) where value < 500: return .orange
        case .measured, .timedOut, .failed: return .red
        }
    }
}

private func nodeProtocolLabel(_ type: String?) -> String {
    guard let type, !type.isEmpty else { return "协议未知" }
    let labels = ["ss": "Shadowsocks", "ssr": "ShadowsocksR", "anytls": "AnyTLS", "vmess": "VMess",
                  "vless": "VLESS", "trojan": "Trojan", "tuic": "TUIC", "hysteria2": "Hysteria2",
                  "wireguard": "WireGuard", "socks5": "SOCKS5", "http": "HTTP", "direct": "Direct",
                  "reject": "Reject", "select": "Selector", "url-test": "URLTest", "load-balance": "LoadBalance"]
    return labels[type.lowercased()] ?? type
}

struct NodeDetailView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var probe: ProbeModel
    let groupName: String
    let node: String
    @State private var selectionError: String?
    @Environment(\.dismiss) private var dismiss

    private var group: LibraryNodeGroup? { model.nodeGroups(connected: probe.isConnected).first { $0.name == groupName } }
    private var measuredDelay: ProxyDelayResult? { model.delayResult(node, groupURL: group?.testURL, connected: probe.isConnected) }

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "network").font(.largeTitle).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node).font(.title3.bold())
                        Text(group?.selected == node ? "当前选中" : group?.canSelect == true ? "可供选择" : "组内成员").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isTestingNode(node, groupURL: group?.testURL) { ProgressView() }
                    else if let delay = measuredDelay { Text(delay.text).font(.headline.monospacedDigit()).foregroundStyle(delay.displayColor) }
                }.padding(.vertical, 12)
            }
            Section("节点信息") {
                LabeledContent("协议", value: nodeProtocolLabel(model.nodeProtocol(node, connected: probe.isConnected)))
                LabeledContent("所属策略组", value: groupName)
                LabeledContent("最近延迟", value: measuredDelay?.text ?? "尚未测试")
            }
            Section {
                if model.isTestingDelays {
                    Button("取消测速", systemImage: "stop.circle") {
                        Task { await model.cancelDelay(using: probe) }
                    }
                } else {
                    Button("重新测试延迟", systemImage: "gauge.with.dots.needle.50percent") { Task { await model.testDelay(node, groupName: groupName, using: probe) } }
                        .disabled(!probe.isConnected)
                }
                if let group, group.canSelect {
                    Button("使用此节点", systemImage: "checkmark.circle") {
                        Task { selectionError = await model.selectNode(node, group: group, using: probe) }
                    }.disabled(group.selected == node || model.busy)
                    Text(probe.isConnected ? "新连接会使用所选出口，已有连接保持原出口。" : model.selectedProfile?.overview?.storeSelected == false ? "离线选择在下次连接时生效，保留至本次应用退出。" : "离线选择保存在本机，下次连接时生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let selectionError { Text(selectionError).font(.footnote).foregroundStyle(.red) }
        }.navigationTitle(node).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("node-detail-close")
                }
            }
    }
}

private struct ProfileGroupsView: View {
    let groups: [YAMLProxyGroup]

    var body: some View {
        List(groups.indices, id: \.self) { index in
            let group = groups[index]
            DisclosureGroup {
                if group.members.isEmpty {
                    Text("此配置未列出成员").foregroundStyle(.secondary)
                } else {
                    ForEach(group.members, id: \.self) { Text($0) }
                }
            } label: {
                LabeledContent(group.name, value: "\(group.members.count)")
            }
        }
        .navigationTitle("策略组")
    }
}
