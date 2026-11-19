import SwiftUI
import UniformTypeIdentifiers

struct ProfileLibraryView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var probe: ProbeModel
    @State private var importing = false
    @State private var addingYAML = false
    @State private var addingSubscription = false
    @State private var search = ""
    @State private var associatingResource: MissingProfileResource?
    @State private var editMode: EditMode = .inactive
    @State private var detailProfileID: String?

    var body: some View {
        List {
            Section {
                ForEach(model.profiles.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }) { profile in
                    HStack(spacing: 0) {
                        Button {
                            Task { await model.select(profile.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: profile.sourceURL == nil ? "doc.text.fill" : "cloud.fill")
                                    .font(.title2).foregroundStyle(profile.sourceURL == nil ? .purple : .blue)
                                    .frame(width: 40)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(profile.displayName).font(.headline)
                                        if model.selectedID == profile.id {
                                            Text("已选择").font(.caption2.bold()).foregroundStyle(.blue)
                                        }
                                    }
                                    Text("\(profile.overview?.proxyNames.count ?? 0) 个节点 · \(profile.overview?.proxyGroups.count ?? 0) 个策略组")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(profile.validationStatus == .invalidYAML ? "YAML 无效，请编辑修复" : "更新于 \(profile.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(profile.validationStatus == .invalidYAML ? .red : .secondary)
                                    if let usage = profile.subscription?.usage { SubscriptionUsageSummary(usage: usage) }
                                }
                            }.padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy || model.downloading || editMode.isEditing || model.selectedID == profile.id)
                        .accessibilityIdentifier("profile-\(profile.id)")
                        .accessibilityValue(model.selectedID == profile.id ? "已选择" : "未选择")
                        Button {
                            detailProfileID = profile.id
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.blue)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看 \(profile.displayName) 详情")
                        .accessibilityIdentifier("info-\(profile.id)")
                    }
                    .moveDisabled(!search.isEmpty || model.busy || model.downloading)
                }
                .onMove { offsets, destination in Task { await model.moveProfiles(from: offsets, to: destination) } }
                if model.profiles.isEmpty {
                    ContentUnavailableView("添加你的第一个配置", systemImage: "doc.badge.plus", description: Text("导入 YAML 文件、订阅链接，或粘贴配置内容。"))
                }
            } header: { Text("配置（\(model.profiles.count)）") }
            Section("运行配置") {
                LabeledContent("当前选择", value: model.selectedProfile?.displayName ?? "未选择")
                Text("连接时自动准备配置与资源。已连接时，切换配置或修改当前配置会自动重连并生效。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("本地资源") {
                if let missing = model.missingResource, missing.profileID == model.selectedID {
                    Text("缺少资源：\(missing.name)").foregroundStyle(.orange)
                    Text(missing.path).font(.caption.monospaced())
                    Button("选择对应资源文件") { associatingResource = missing }
                        .accessibilityIdentifier("associateLocalResource")
                }
                ForEach(model.resourceFiles) { link in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(link.displayName)
                        Text(link.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(link.size), countStyle: .file)).font(.caption)
                            Spacer()
                            Button("解除关联", role: .destructive) { Task { await model.removeResource(link) } }.font(.caption)
                        }
                    }
                }
                if model.resourceFiles.isEmpty && model.missingResource == nil {
                    Text("配置所需的本地文件资源会在这里显示。").foregroundStyle(.secondary)
                }
            }.disabled(model.busy || model.selectedProfile == nil)
            Section("添加配置") {
                Button("从链接导入", systemImage: "link") { addingSubscription = true }
                Button("导入 YAML 文件", systemImage: "doc.badge.plus") { importing = true }
                Button("粘贴 YAML", systemImage: "doc.on.clipboard") { addingYAML = true }
                Button("添加 DIRECT 示例", systemImage: "doc.text") { Task { await model.addDirectExample() } }
                    .accessibilityIdentifier("addDirectExample")
            }.disabled(model.busy)
            SubscriptionUpdateResultsView(model: model)
            Section { Text(model.message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled).accessibilityIdentifier("profile-operation-status") }
        }
        .navigationTitle("配置")
        .navigationDestination(item: $detailProfileID) { id in
            if let profile = model.profiles.first(where: { $0.id == id }) {
                ProfileDetailView(model: model, probe: probe, profile: profile)
            }
        }
        .environment(\.editMode, $editMode)
        .searchable(text: $search, prompt: "搜索配置")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(editMode.isEditing ? "完成" : "手动排序") {
                    editMode = editMode.isEditing ? .inactive : .active
                }.disabled(!search.isEmpty || model.busy || model.downloading || model.profiles.count < 2)
                    .accessibilityIdentifier("sortProfiles")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("更新全部订阅", systemImage: "arrow.triangle.2.circlepath") { model.updateSubscriptions(model.profiles) }
                        .disabled(model.downloading || model.busy || !model.profiles.contains { $0.sourceURL != nil })
                    Button("从链接导入", systemImage: "link") { addingSubscription = true }
                    Button("导入 YAML 文件", systemImage: "doc") { importing = true }
                    Button("粘贴 YAML", systemImage: "plus") { addingYAML = true }
                } label: { Image(systemName: "plus.circle.fill") }.accessibilityLabel("添加配置")
            }
        }
        .refreshable { _ = await model.run { try await model.refreshProfiles() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.yaml, .plainText, .data]) { result in
            switch result {
            case .success(let url): Task { await model.importFile(url) }
            case .failure: model.message = "文件未导入，请重新选择。"
            }
        }
        .sheet(isPresented: $addingYAML) { LibraryEditorView(model: model, profile: nil) }
        .sheet(isPresented: $addingSubscription) { SubscriptionEntryView(model: model) }
        .sheet(item: $associatingResource) { LibraryResourceAssociationView(model: model, request: $0) }
    }
}

struct NodeLibraryView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var probe: ProbeModel
    var title = "节点"
    @State private var search = ""
    @State private var expandedGroups: Set<String> = []
    @State private var collapsedSearchGroups: Set<String> = []
    @State private var detail: NodeDetailDestination?
    @State private var scrollTarget: NodeDetailDestination?
    @State private var operationMessage: String?

    init(model: LibraryModel, probe: ProbeModel, title: String = "节点", initiallyExpandedGroup: String? = nil) {
        self.model = model
        self.probe = probe
        self.title = title
        _expandedGroups = State(initialValue: Set([initiallyExpandedGroup].compactMap { $0 }))
    }

    private func isExpanded(_ group: String) -> Bool {
        search.isEmpty ? expandedGroups.contains(group) : !collapsedSearchGroups.contains(group)
    }

    private func setExpanded(_ groups: Set<String>, to expanded: Bool) {
        if search.isEmpty {
            if expanded { expandedGroups.formUnion(groups) }
            else { expandedGroups.subtract(groups) }
        } else {
            if expanded { collapsedSearchGroups.subtract(groups) }
            else { collapsedSearchGroups.formUnion(groups) }
        }
    }

    var body: some View {
        let groups = model.nodeGroups(connected: probe.isConnected)
        let matches = groups.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || !matchingNodes($0).isEmpty }
        ScrollViewReader { reader in
            List {
                ForEach(matches) { group in
                    let expanded = isExpanded(group.name)
                    Section {
                        groupHeader(group, expanded: expanded)
                        if expanded {
                            ForEach(model.visibleNodes(matchingNodes(group), groupURL: group.testURL, connected: probe.isConnected), id: \.self) { node in
                                StrategyNodeRow(model: model, probe: probe, group: group, node: node, detail: $detail)
                                    .id(NodeDetailDestination(groupName: group.name, node: node))
                            }
                        }
                    }
                }
                if groups.isEmpty {
                    Section {
                        ContentUnavailableView(
                            model.selectedProfile == nil ? "尚未选择配置" : "暂无可选策略组",
                            systemImage: "network",
                            description: Text("选择含有策略组的配置，即可查看或切换组内节点。")
                        )
                        NavigationLink("打开配置列表") { ProfileLibraryView(model: model, probe: probe) }
                            .accessibilityIdentifier("nodes-open-profiles")
                    }
                } else if matches.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                if let warnings = model.catalog?.warnings, probe.isConnected, !warnings.isEmpty {
                    DisclosureGroup("兼容性说明") {
                        ForEach(warnings, id: \.self) { Text($0).font(.footnote) }
                    }
                }
                if let operationMessage {
                    Text(operationMessage).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { reader.scrollTo(target, anchor: .center) }
                scrollTarget = nil
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { searchBar }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detail) { destination in
            NavigationStack {
                NodeDetailView(model: model, probe: probe, groupName: destination.groupName, node: destination.node)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                let names = Set(matches.map(\.name))
                let allCollapsed = names.allSatisfy { !isExpanded($0) }
                if model.isTestingDelays {
                    Button("取消测速", systemImage: "stop.circle") {
                        Task { await model.cancelDelay(using: probe) }
                    }
                    .accessibilityIdentifier("nodes-cancel-test")
                } else {
                    Button("全部测速", systemImage: "bolt.fill") {
                        setExpanded(Set(groups.map(\.name)), to: true)
                        Task { await model.testAllDelays(using: probe) }
                    }
                    .disabled(!probe.isConnected || groups.isEmpty)
                    .accessibilityIdentifier("nodes-test-all")
                }
                Button(allCollapsed ? "全部展开" : "全部收起", systemImage: allCollapsed ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left") {
                    setExpanded(names, to: allCollapsed)
                }
                .disabled(names.isEmpty)
                .accessibilityIdentifier("nodes-toggle-all")
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await model.refreshCatalog(using: probe) }
                }
                .accessibilityIdentifier("nodes-refresh")
                ProxyDelayDisplayMenu(model: model)
            }
        }
        .onChange(of: search) { _, _ in collapsedSearchGroups.removeAll() }
        .onChange(of: model.message) { _, value in operationMessage = value }
        .task(id: probe.isConnected) { await model.refreshCatalog(using: probe) }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索节点或策略组", text: $search)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(.search)
                .accessibilityIdentifier("nodes-search")
            if !search.isEmpty {
                Button("清除搜索", systemImage: "xmark.circle.fill") { search = "" }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 40)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private func matchingNodes(_ group: LibraryNodeGroup) -> [String] {
        if search.isEmpty || group.name.localizedCaseInsensitiveContains(search) { return group.members }
        return ProxyDelayPreferences.matching(group.members, search: search)
    }

    private func groupHeader(_ group: LibraryNodeGroup, expanded: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                toggle(group.name)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).font(.headline).lineLimit(1)
                    HStack(spacing: 4) {
                        Text([group.type, group.selected].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary).lineLimit(1)
                        if let node = group.selected,
                           let delay = model.delayResult(node, groupURL: group.testURL, connected: probe.isConnected) {
                            Text(delay.text).foregroundStyle(delay.displayColor).fixedSize()
                        }
                    }.font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(group.name)
            .accessibilityValue(expanded ? "已展开" : "已收起")
            .accessibilityIdentifier("node-group-\(group.name)")
            Button {
                guard let node = group.selected else { return }
                search = ""
                expandedGroups.insert(group.name)
                scrollTarget = NodeDetailDestination(groupName: group.name, node: node)
            } label: {
                Image(systemName: "scope").frame(width: 42, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(group.selected.map { model.visibleNodes([$0], groupURL: group.testURL, connected: probe.isConnected).isEmpty } ?? true)
            .accessibilityLabel("定位当前成员")
            .accessibilityIdentifier("locate-group-\(group.name)")
            Button {
                setExpanded([group.name], to: true)
                Task { await model.testDelays(group.members, groupURL: group.testURL, using: probe) }
            } label: {
                Image(systemName: "bolt").frame(width: 42, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!probe.isConnected || model.isTestingDelays || group.members.isEmpty)
            .accessibilityLabel("整组测速")
            .accessibilityIdentifier("test-group-\(group.name)")
            Button {
                toggle(group.name)
            } label: {
                HStack(spacing: 5) {
                    Text("\(group.members.count)").font(.subheadline.monospacedDigit())
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }.frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(group.members.count) 个成员，\(expanded ? "收起" : "展开")")
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ group: String) {
        setExpanded([group], to: !isExpanded(group))
    }
}

struct YAMLSyncView: View {
    @ObservedObject var model: LibraryModel
    @State private var selecting = false
    @State private var confirming = false

    private var pendingCount: Int { model.syncResults.filter { model.hasBlockedSync($0.fileName) }.count }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "icloud.fill").font(.largeTitle).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.syncBusy ? "正在同步" : pendingCount > 0 ? "\(pendingCount) 个文件待处理" : !model.syncEnabled && model.syncDirectory != nil ? "自动同步已暂停" : model.syncArmed ? "同步已开启" : "选择同步文件夹")
                            .font(.headline)
                        Text(model.syncResults.isEmpty ? "选择专用文件夹，同步原始 YAML" : "已扫描 \(model.syncResults.count) 个文件")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            Section {
                Toggle("自动同步", isOn: Binding(get: { model.syncEnabled }, set: model.setSyncEnabled))
                    .disabled(model.syncDirectory == nil || model.syncBusy)
                Button { selecting = true } label: {
                    HStack {
                        Label("选择同步文件夹", systemImage: "folder")
                        Spacer()
                        if let directory = model.syncDirectory { Text(directory.lastPathComponent).font(.caption).foregroundStyle(.secondary) }
                    }
                }.disabled(model.syncBusy || model.busy || model.downloading)
                Text("可选择 iCloud Drive 或本地文件夹。iCloud 的跨设备传输由系统管理，本地文件夹不会上传到 iCloud。应用在前台每 30 秒检查一次。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    if model.syncArmed { Task { await model.synchronize() } }
                    else { confirming = true }
                } label: {
                    HStack { Spacer(); if model.syncBusy { ProgressView() }; Text(model.syncArmed ? "立即同步" : "开始首次同步"); Spacer() }
                }
                .disabled(model.syncDirectory == nil || !model.syncEnabled || model.syncBusy || model.busy)
                .accessibilityIdentifier("startCloudSync")
            }
            Section("文件（\(model.syncResults.count)）") {
                if model.syncResults.isEmpty { Text("尚未扫描").foregroundStyle(.secondary) }
                ForEach(model.syncResults, id: \.fileName) { result in
                    switch result.status {
                    case .conflict(let conflict):
                        NavigationLink { YAMLConflictView(model: model, fileName: result.fileName, conflict: conflict) } label: {
                            syncFile(result.fileName, detail: "内容冲突，需要选择版本", color: .orange)
                        }
                    case .remoteDeletionConflict(let localHash):
                        NavigationLink { RemoteDeletionConflictView(model: model, fileName: result.fileName, localHash: localHash) } label: {
                            syncFile(result.fileName, detail: "远端已删除，本地有修改", color: .orange)
                        }
                    case .providerConflict(let versions):
                        NavigationLink { ProviderConflictView(fileName: result.fileName, versions: versions) } label: {
                            syncFile(result.fileName, detail: "文件提供方版本冲突", color: .orange)
                        }
                    default:
                        syncFile(result.fileName, detail: syncStatusText(result.status), color: .secondary)
                    }
                }
            }
            Section {
                NavigationLink { CloudBackupsView(model: model) } label: { Label("同步备份", systemImage: "archivebox") }
                    .accessibilityIdentifier("cloudBackups")
                Text("订阅地址与节点选择仅保存在本机。同步更新当前运行配置后会自动重连。同步目录中已删除的配置会从本地移除并备份；本地有修改时需先处理冲突。删除本地配置会保留同步目录中的文件。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section { Text(model.message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .navigationTitle("iCloud 同步")
        .sheet(isPresented: $confirming) { CloudFirstSyncView(model: model) }
        .fileImporter(isPresented: $selecting, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await model.chooseSyncDirectory(url) }
            case .failure: model.message = "未选择同步目录。"
            }
        }
    }

    private func syncFile(_ name: String, detail: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text").foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 4) { Text(name); Text(detail).font(.caption).foregroundStyle(color) }
        }.padding(.vertical, 3)
    }
}

private func syncStatusText(_ status: YAMLSyncStatus) -> String {
    switch status {
    case .uploaded: "已写入同步目录"
    case .downloaded: "已同步到本地"
    case .identical: "两端内容一致"
    case .deletedLocally: "远端删除已同步，本地内容已备份"
    case .remoteDeletionConflict: "远端已删除，本地有修改，待选择处理方式"
    case .missing: "本地已移除，保留同步目录中的文件"
    case .waitingDownload: "等待文件提供方下载"
    case .conflict: "内容冲突"
    case .providerConflict: "文件提供方版本冲突"
    case .failed(let reason): "未同步：\(reason)"
    }
}
