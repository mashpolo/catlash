import SwiftUI

private enum HomeDestination: Hashable { case profile(String), profiles, cloud, recovery, traffic, settings, rules, effectiveConfiguration }

struct HomeView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel
    @State private var preparing = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var showRecovery = false
    @State private var showProxies = false
    @State private var showExitIP = false
    @AppStorage("hideExitIP") private var hideExitIP = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                connectionCard
                if model.isConnected, let runningID = model.activeRuntimeProfileID,
                   library.syncDeletedProfileIDs.contains(runningID),
                   !library.profiles.contains(where: { $0.id == runningID }) {
                    Text("运行配置已从同步目录删除，现有 VPN 会话继续运行。选择其他配置后再切换。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("home-running-profile-deleted")
                }
                if preparing || library.isUpdatingConfiguration {
                    Text(library.preparationMessage.isEmpty ? "正在准备配置…" : library.preparationMessage)
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("connection-preparation-progress")
                } else if model.isStarting || model.isConnecting {
                    Text(model.message).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("connection-startup-progress")
                } else if let failure = model.connectionFailure {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                        .textSelection(.enabled).accessibilityIdentifier("connection-failure")
                }
                if model.isConnected, let resources = model.resourceStatus, resources.operationID == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(resources.message)
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("connection-resource-status")
                        if resources.phase == .failed {
                            Button("重试资源", systemImage: "arrow.clockwise") {
                                Task { await model.retryResources() }
                            }
                            .font(.footnote)
                            .accessibilityIdentifier("connection-resource-retry")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                modeCard
                Button { showProxies = true } label: {
                    ClientCard { homeRow(title: "代理", detail: library.proxyOverview(connected: model.isConnected), symbol: "server.rack") }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-nodes")
                NavigationLink(value: HomeDestination.rules) {
                    ClientCard { homeRow(title: "规则", detail: "浏览、搜索与编辑配置规则", symbol: "list.bullet.rectangle") }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-rules")
                NavigationLink(value: HomeDestination.effectiveConfiguration) {
                    Label("查看生效中的配置", systemImage: "doc.text.magnifyingglass")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .accessibilityIdentifier("home-effective-configuration")
                HStack(spacing: 12) {
                    trafficCard("上传", symbol: "arrow.up", color: .secondary, rate: model.runtime.uploadRateText, total: model.runtime.uploadTotalText)
                    trafficCard("下载", symbol: "arrow.down", color: .accentColor, rate: model.runtime.downloadRateText, total: model.runtime.downloadTotalText)
                }
                profileCard
                NavigationLink(value: HomeDestination.cloud) {
                    ClientCard {
                        HStack {
                            ClientRow(title: cloudTitle, symbol: "icloud", detail: cloudDetail, color: .blue)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-cloud")
                if !ProbeModel.supportsVPN {
                    Text("模拟器支持配置、节点与同步管理。VPN 连接需在 iPhone 上验证。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(ClientPalette.background)
        .navigationTitle("Catlash")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: HomeDestination.settings) { Image(systemName: "gearshape") }
                .accessibilityLabel("设置")
            }
        }
        .task(id: model.isConnected) { await library.refreshCatalog(using: model) }
        .navigationDestination(for: HomeDestination.self) { destination in
            switch destination {
            case .profile(let id):
                if let profile = library.profiles.first(where: { $0.id == id }) {
                    ProfileDetailView(model: library, probe: model, profile: profile)
                } else {
                    ContentUnavailableView("配置文件已移除", systemImage: "doc")
                }
            case .profiles: ProfileLibraryView(model: library, probe: model)
            case .cloud: YAMLSyncView(model: library)
            case .recovery: ConnectionRecoveryView(model: model, library: library)
            case .traffic: TrafficStatusView(model: model)
            case .settings: MoreView(model: model, library: library)
            case .rules: RuleLibraryView(model: library)
            case .effectiveConfiguration: EffectiveConfigurationView(model: model, library: library)
            }
        }
        .sheet(isPresented: $showProxies) {
            NavigationStack {
                NodeLibraryView(model: library, probe: model, title: "代理", initiallyExpandedGroup: model.isConnected ? library.activeGlobalGroup?.name : nil)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("关闭", systemImage: "xmark") { showProxies = false }
                                .accessibilityIdentifier("close-proxies")
                        }
                    }
            }
        }
        .sheet(isPresented: $showExitIP) { NavigationStack { ExitIPDetailView(model: model, library: library) } }
        .navigationDestination(isPresented: $showRecovery) { ConnectionRecoveryView(model: model, library: library) }
    }

    private var connectionCard: some View {
        ClientCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("状态", systemImage: "waveform.path.ecg").font(.subheadline.weight(.semibold))
                    Text(model.isConnected ? "● 运行中" : connectionStatus)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.isConnected ? Color.green : Color.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background((model.isConnected ? Color.green : Color.secondary).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Spacer()
                    Button { model.refreshExitIP(forceRefresh: true) } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 32, height: 32)
                    }
                    .disabled(!model.isConnected || model.exitIP.isLoading)
                    .accessibilityLabel("刷新出口 IP")
                    .accessibilityIdentifier("home-ip-refresh")
                }
                HStack(alignment: .center, spacing: 12) {
                    Button { showExitIP = true } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text(model.exitIP.result?.countryCode ?? "—")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 42, height: 48)
                                .background(Color.secondary.opacity(0.12), in: ConnectionFlower())
                                .accessibilityIdentifier("home-ip-country")
                            VStack(alignment: .leading, spacing: 8) {
                                Text(exitIPTitle)
                                    .font(.title3.weight(.bold)).monospacedDigit()
                                    .foregroundStyle(model.exitIP.result?.qualityDetails?.level.color ?? .primary)
                                    .lineLimit(2).minimumScaleFactor(0.75)
                                    .accessibilityIdentifier("home-exit-ip")
                                if let result = model.exitIP.result {
                                    Text(result.addressFamily).font(.caption2).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("home-ip-family")
                                }
                                HStack(spacing: 5) {
                                    ipBadge(model.exitIP.result?.networkType ?? "未检测")
                                    ipBadge("质量 " + (model.exitIP.result?.quality ?? "未知"))
                                        .foregroundStyle(model.exitIP.result?.qualityDetails?.level.color ?? .primary)
                                        .accessibilityIdentifier("home-ip-quality")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-ip-details")
                    Button(action: toggleConnection) {
                        ZStack {
                            ConnectionFlower().fill(Color.accentColor.gradient)
                            if preparing || model.isStarting || model.isConnecting {
                                ProgressView().tint(.white).controlSize(.large)
                            } else {
                                Image(systemName: model.isConnected ? "pause.fill" : "power")
                                    .font(.title.weight(.semibold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 72, height: 72)
                        .shadow(color: Color.accentColor.opacity(0.22), radius: 12, y: 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!ProbeModel.supportsVPN || (!model.isConnected && !(model.isStarting || model.isConnecting) && !preparing && (library.selectedProfile == nil || library.busy || model.isPreparingSnapshot)))
                    .accessibilityLabel(connectionAction)
                    .accessibilityIdentifier("home-connect")
                }
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("运行时长").font(.caption).foregroundStyle(.secondary)
                        if let since = model.connectedSince {
                            Text(since, style: .timer).font(.subheadline.weight(.semibold).monospacedDigit())
                        } else { Text("—").font(.subheadline) }
                    }
                    .frame(minWidth: 88, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("组织").font(.caption).foregroundStyle(.secondary)
                        Text(model.exitIP.result?.organization ?? "—")
                            .font(.subheadline.weight(.semibold)).lineLimit(2)
                            .accessibilityIdentifier("home-ip-organization")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.isConnected {
                    Text(model.activeRuntimeScope ?? "正在读取实际运行范围…")
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("home-runtime-scope")
                }
            }
        }
    }

    private var exitIPTitle: String {
        if let result = model.exitIP.result { return hideExitIP ? "*****" : result.ip }
        if !model.isConnected { return "连接后检测 IP" }
        if model.exitIP.isLoading { return "正在检测 IP…" }
        return model.exitIP.error == nil ? "等待检测 IP" : "IP 检测失败"
    }

    private func ipBadge(_ title: String) -> some View {
        Text(title).font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var modeCard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach([("rule", "规则", "list.bullet.rectangle"), ("global", "全局", "globe"), ("direct", "直连", "arrow.up.right.circle")], id: \.0) { mode, title, symbol in
                    Button {
                        Task { await library.setRoutingMode(mode, using: model) }
                    } label: {
                        Label(title, systemImage: symbol)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .foregroundStyle(currentMode == mode ? Color.white : Color.primary)
                            .background(currentMode == mode ? Color.accentColor : Color.secondary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.isConnected || library.catalog?.proxies.contains(where: { $0.name == "GLOBAL" }) != true || library.busy)
                    .accessibilityIdentifier("home-mode-" + mode)
                    .accessibilityAddTraits(currentMode == mode ? .isSelected : [])
                }
            }
            .padding(5)
            .background(ClientPalette.surface, in: RoundedRectangle(cornerRadius: ClientPalette.cardRadius, style: .continuous))
            if library.requestedMode != nil {
                HStack(spacing: 6) { ProgressView(); Text("正在切换模式…").font(.caption) }
            } else if let error = library.modeError {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("home-mode-error")
            } else if !model.isConnected {
                Text("连接 YAML 配置后可切换模式").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func trafficCard(_ title: String, symbol: String, color: Color, rate: String, total: String) -> some View {
        NavigationLink(value: HomeDestination.traffic) {
            ClientCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(color)
                    Text(rate).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .accessibilityIdentifier(title == "上传" ? "home-upload-rate" : "home-download-rate")
                    Text("累计 " + total).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier(title == "上传" ? "home-upload-total" : "home-download-total")
                        .accessibilityValue(model.runtime.snapshot.map { String(title == "上传" ? $0.uploadTotal : $0.downloadTotal) } ?? "未采集")
                    if !model.runtime.isFresh {
                        Text(model.isConnected ? "等待有效采样" : "VPN 未连接").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var profileCard: some View {
        ClientCard {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    NavigationLink(value: profileDestination) {
                        homeRow(title: model.isConnected ? "运行配置" : "当前配置", detail: profileTitle, symbol: "doc.text")
                    }
                    .accessibilityIdentifier(profileDestination == .profiles ? "home-profiles" : "home-current-profile")
                    if profileDestination != .profiles {
                        Divider()
                        NavigationLink("配置库", value: HomeDestination.profiles)
                            .font(.subheadline)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("home-profiles")
                    }
                }
                Divider().padding(.leading, 46)
                NavigationLink(value: HomeDestination.recovery) {
                    HStack {
                        Label("连接详情", systemImage: "arrow.clockwise.circle").font(.footnote)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("home-recovery")
            }
        }
        .buttonStyle(.plain)
    }

    private func homeRow(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private var connectionStatus: String { preparing ? "准备配置" : library.isUpdatingConfiguration ? "正在更新配置" : !ProbeModel.supportsVPN ? "未连接" : model.statusText }
    private var connectionAction: String { preparing || (model.isStarting || model.isConnecting) ? "取消连接" : model.isConnected ? "断开连接" : "连接" }
    private var currentMode: String? { model.isConnected ? library.catalog?.mode.lowercased() : nil }
    private var profileDestination: HomeDestination {
        if model.isConnected {
            if let id = model.activeRuntimeProfileID, library.profiles.contains(where: { $0.id == id }) {
                return .profile(id)
            }
            return .effectiveConfiguration
        }
        return library.selectedProfile.map { .profile($0.id) } ?? .profiles
    }
    private var profileTitle: String {
        guard model.isConnected else { return library.selectedProfile?.displayName ?? "导入 YAML 或添加订阅" }
        if let id = model.activeRuntimeProfileID {
            return library.profiles.first { $0.id == id }?.displayName ?? "运行中的 YAML 配置"
        }
        if let scope = model.activeRuntimeScope { return scope }
        return "正在读取实际运行配置"
    }
    private var cloudTitle: String { library.syncBusy ? "iCloud 同步中" : library.syncEnabled ? "iCloud 同步已开启" : "iCloud 同步" }
    private var cloudDetail: String { library.syncDirectory?.lastPathComponent ?? "选择文件夹，同步 YAML 配置" }

    private func toggleConnection() {
        if preparing {
            connectionTask?.cancel()
        } else if model.isConnected || (model.isStarting || model.isConnecting) {
            model.disconnect()
        } else {
            preparing = true
            model.beginConnectionPreparation()
            connectionTask = Task { @MainActor in
                defer { preparing = false; connectionTask = nil }
                let prepared = await library.stageSelected(using: model)
                guard !Task.isCancelled else { return }
                if prepared { model.connect() }
                else { model.preparationFailed(library.message); showRecovery = true }
            }
        }
    }
}

struct ConnectionRecoveryView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel

    var body: some View {
        Form {
            Section {
                ClientNotice(title: model.statusText, message: model.message, symbol: model.isConnected ? "checkmark.shield" : "network")
                Text(library.message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section {
                NavigationLink("查看配置", destination: ProfileLibraryView(model: library, probe: model))
                NavigationLink("基础连接诊断", destination: ConnectionView(model: model))
            }
        }
        .navigationTitle("连接详情").navigationBarTitleDisplayMode(.inline)
    }
}

private struct TrafficStatusView: View {
    @ObservedObject var model: ProbeModel
    var body: some View {
        Form {
            Section {
                LabeledContent("VPN 状态", value: model.statusText)
                RuntimeStatusView(model: model)
            }
            Section("实时速率") {
                LabeledContent("上传", value: model.runtime.uploadRateText)
                LabeledContent("下载", value: model.runtime.downloadRateText)
            }
            Section("本次内核会话累计") {
                LabeledContent("上传", value: model.runtime.uploadTotalText)
                LabeledContent("下载", value: model.runtime.downloadTotalText)
                Text("切换运行配置或重启内核后重新累计。首次采样只读取累计值，第二次采样开始显示速率。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("流量统计").navigationBarTitleDisplayMode(.inline)
    }
}
