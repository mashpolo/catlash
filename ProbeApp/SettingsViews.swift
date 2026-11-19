import SwiftUI

struct OnDemandSettingsView: View {
    @ObservedObject var model: ProbeModel
    @State private var draft = OnDemandPolicy()
    @State private var editing: OnDemandRule?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $draft.enabled) {
                    ClientRow(title: "启用按需连接", symbol: "bolt.horizontal.circle.fill", color: .cyan)
                }
                LabeledContent("系统状态", value: systemStatus)
            } footer: {
                Text(ProbeModel.supportsVPN ? "点击保存后才更新系统规则。启用后，系统可按规则自动连接或断开 VPN。" : "模拟器只能保存草稿，不会安装系统规则或自动连接 VPN。")
            }
            Section {
                if draft.rules.isEmpty { Text("尚无规则").foregroundStyle(.secondary) }
                ForEach(draft.rules) { rule in
                    Button { editing = rule } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(rule.name).foregroundStyle(.primary)
                            Text(ruleDescription(rule)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { draft.rules.remove(atOffsets: $0) }
                .onMove { draft.rules.move(fromOffsets: $0, toOffset: $1) }
                Button { editing = OnDemandRule(name: "", network: .wifi, action: .disconnect) } label: {
                    Label("添加网络规则", systemImage: "plus")
                }.accessibilityIdentifier("ondemand-rule")
            } header: {
                Text("网络规则")
            } footer: {
                Text("从上到下匹配，第一条匹配规则生效。Wi-Fi 的 SSID 留空表示所有 Wi-Fi；未匹配的网络保持当前 VPN 状态。可通过编辑按钮调整顺序。")
            }
            Section {
                Button(ProbeModel.supportsVPN ? "保存到系统" : "保存草稿") {
                    Task {
                        if await model.saveOnDemandPolicy(draft) { draft = model.onDemandPolicy }
                    }
                }.accessibilityIdentifier("ondemand-save")
                Button("重新读取") { Task { await reload() } }
                if !model.onDemandMessage.isEmpty {
                    Text(model.onDemandMessage).font(.footnote).textSelection(.enabled)
                        .accessibilityIdentifier("ondemand-result")
                }
            }
            Section {
                Text("首次启用前，请先从首页连接一次。按需连接使用系统记录的配置；离线修改配置后，需连接一次以更新系统记录。若按需连接仍启用，手动断开后系统可能按规则重新连接；关闭开关并保存可停止自动连接。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(model.onDemandBusy || model.isStarting || model.isConnecting || !loaded)
        .navigationTitle("按需连接").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .task { await reload(); loaded = true }
        .sheet(item: $editing) { rule in
            NavigationStack {
                OnDemandRuleView(rule: rule) { value in
                    if let index = draft.rules.firstIndex(where: { $0.id == value.id }) { draft.rules[index] = value }
                    else { draft.rules.append(value) }
                }
            }
        }
    }

    private var systemStatus: String {
        guard ProbeModel.supportsVPN else { return "模拟器：未启用" }
        guard let enabled = model.onDemandSystemEnabled else { return "未确认，请重新读取" }
        return enabled ? "已启用" : "未启用"
    }

    private func reload() async {
        await model.loadOnDemandPolicy()
        draft = model.onDemandPolicy
    }

    private func ruleDescription(_ rule: OnDemandRule) -> String {
        let network = rule.network == .wifi ? (rule.ssid.isEmpty ? "所有 Wi-Fi" : "Wi-Fi · " + rule.ssid) : rule.network == .cellular ? "蜂窝网络" : "任意网络"
        let action = rule.action == .connect ? "连接 VPN" : rule.action == .disconnect ? "断开 VPN" : "保持当前状态"
        return network + " → " + action
    }
}

private struct OnDemandRuleView: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: OnDemandRule
    let save: (OnDemandRule) -> Void
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                TextField("规则名称", text: $rule.name)
                    .accessibilityIdentifier("ondemand-rule-name")
                Picker("网络类型", selection: $rule.network) {
                    Text("Wi-Fi").tag(OnDemandRule.Network.wifi)
                    Text("蜂窝网络").tag(OnDemandRule.Network.cellular)
                    Text("任意网络").tag(OnDemandRule.Network.any)
                }
                if rule.network == .wifi {
                    TextField("SSID（留空匹配所有 Wi-Fi）", text: $rule.ssid)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            Section("匹配后行为") {
                Picker("匹配后行为", selection: $rule.action) {
                    Text("断开 VPN").tag(OnDemandRule.Action.disconnect)
                    Text("连接 VPN").tag(OnDemandRule.Action.connect)
                    Text("保持当前状态").tag(OnDemandRule.Action.ignore)
                }.pickerStyle(.inline).labelsHidden()
            }
            if !message.isEmpty { Section { Text(message).foregroundStyle(.red) } }
            Section { Text("此页只修改草稿。返回按需连接页面后，点击保存才会生效。") }
        }
        .navigationTitle("网络规则").navigationBarTitleDisplayMode(.inline)
        .onChange(of: rule.network) { _, network in if network != .wifi { rule.ssid = "" } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    do {
                        try OnDemandPolicy(rules: [rule]).validate()
                        save(rule)
                        dismiss()
                    } catch { message = error.localizedDescription }
                }
            }
        }
    }
}

struct VPNSettingsView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel
    @State private var configuration: TunnelSettingsSummary?
    @State private var configurationMessage = ""
    @State private var loadGeneration: UInt64 = 0

    var body: some View {
        Form {
            Section("连接状态") {
                ClientRow(title: "VPN", symbol: "shield.lefthalf.filled", detail: model.statusText)
                LabeledContent("连接方式", value: model.onDemandSystemEnabled == true ? "系统按需连接" : "手动")
            }
            Section("当前连接") {
                if let configuration {
                    ClientRow(title: "路由策略", symbol: "arrow.triangle.branch", detail: usesYAML ? "YAML 默认路由" : "仅 1.1.1.1")
                    ClientRow(title: "DNS", symbol: "network", detail: usesYAML ? "按当前配置与 DNS 覆盖项生成" : "使用系统 DNS", color: .cyan)
                    ClientRow(title: "IPv6", symbol: "globe", detail: usesYAML ? "由 YAML 决定" : "未启用", color: .purple)
                    LabeledContent("MTU", value: String(configuration.mtu))
                } else {
                    Text(configurationMessage.isEmpty ? "连接后显示实际隧道设置" : configurationMessage).foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink("DNS 与 TUN 覆盖") { DNSOverrideSettingsView(library: library) }
                    .accessibilityIdentifier("vpn-dns-overrides")
            } footer: {
                Text("已连接时，保存覆盖项会自动重连并生效。未连接时，在下次连接时生效。")
            }
            Section {
                NavigationLink("基础连接诊断") { ConnectionView(model: model) }
                    .accessibilityIdentifier("vpn-diagnostics")
            }
        }
        .navigationTitle("VPN").navigationBarTitleDisplayMode(.inline)
        .task(id: model.activeRuntimeRevision) { await loadConfiguration() }
    }

    private var usesYAML: Bool {
        configuration?.usesYAML == true
    }

    private func loadConfiguration() async {
        guard !Task.isCancelled else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        configuration = nil
        configurationMessage = ""
        guard let revision = model.activeRuntimeRevision else { return }
        configurationMessage = "正在读取连接设置…"
        do {
            let root = try model.snapshotDirectory()
            let configuration = try await Task.detached(priority: .utility) {
                let configuration = try RuntimeConfiguration.decode(SnapshotStore(root: root).load(revision: revision))
                return TunnelSettingsSummary(configuration: configuration)
            }.value
            guard generation == loadGeneration, !Task.isCancelled, model.activeRuntimeRevision == revision else { return }
            self.configuration = configuration
            configurationMessage = ""
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, model.activeRuntimeRevision == revision else { return }
            configuration = nil
            configurationMessage = "无法读取连接设置：\(error.localizedDescription)"
        }
    }
}

private struct TunnelSettingsSummary: Sendable {
    let mtu: Int
    let usesYAML: Bool

    init(configuration: RuntimeConfiguration) {
        mtu = configuration.mtu
        if case .mihomo = configuration.outbound { usesYAML = true }
        else { usesYAML = false }
    }
}

struct ClientSettingsView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel

    var body: some View {
        Form {
            Section("连接与启动") {
                ClientRow(title: "打开应用", symbol: "app.badge", detail: "恢复状态，不自动连接")
                ClientRow(title: "节点选择", symbol: "point.3.connected.trianglepath.dotted", detail: "仅保存在本机", color: .purple)
            }
            Section("显示") {
                NavigationLink { AppearanceSettingsView() } label: {
                    ClientRow(title: "外观与文字", symbol: "textformat.size", color: .pink)
                }
                LabeledContent("实时速率", value: "连接后每秒采样")
            }
            Section("节点") {
                NavigationLink { ProxyDelaySettingsView(model: library) } label: {
                    ClientRow(title: "节点测速设置", symbol: "gauge.with.dots.needle.50percent", color: .cyan)
                }.accessibilityIdentifier("proxy-delay-settings")
            }
            Section {
                NavigationLink { ProfileLibraryView(model: library, probe: model) } label: {
                    ClientRow(title: "管理配置与订阅", symbol: "doc.text", detail: "手动更新")
                }
                NavigationLink { YAMLSyncView(model: library) } label: {
                    ClientRow(title: "iCloud 自动同步", symbol: "icloud", detail: library.syncEnabled ? "已开启" : "未开启", color: .cyan)
                }
            } header: {
                Text("配置与更新")
            } footer: {
                Text("自动同步在应用前台运行，间隔 30 秒，也会响应文件变化。当前运行配置更新后会自动重连并生效。")
            }
        }
        .navigationTitle("客户端设置").navigationBarTitleDisplayMode(.inline)
    }
}
