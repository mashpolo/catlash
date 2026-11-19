import SwiftUI

struct ProxyDelaySettingsView: View {
    @ObservedObject var model: LibraryModel
    @State private var url = ""
    @State private var timeout = ""
    @State private var message = ""

    var body: some View {
        Form {
            Section("测速请求") {
                TextField("测速 URL", text: $url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("proxy-test-url")
                TextField("超时（毫秒）", text: $timeout)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("proxy-test-timeout")
                Text("超时范围为 1–60000 毫秒。策略组在 YAML 中配置了测速 URL 时优先使用组内地址，其他情况使用这里的地址。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("保存测速设置") {
                    do {
                        guard let value = Int(timeout) else { throw ProxyDelaySettingsError.invalidTimeout }
                        var preferences = model.delayPreferences
                        preferences.settings = ProxyDelaySettings(url: url.trimmingCharacters(in: .whitespacesAndNewlines), timeoutMilliseconds: value)
                        try preferences.settings.validate()
                        if model.saveDelayPreferences(preferences) { message = "已保存，下次测速生效。" }
                        else { message = model.message }
                    } catch { message = error.localizedDescription }
                }.accessibilityIdentifier("proxy-test-save")
                Button("恢复默认值") {
                    let settings = ProxyDelaySettings()
                    url = settings.url
                    timeout = String(settings.timeoutMilliseconds)
                    message = "点击保存后生效。"
                }
                if !message.isEmpty { Text(message).font(.footnote).accessibilityIdentifier("proxy-test-settings-result") }
            }
            Section {
                Text("测速只在 VPN 连接后执行。整组最多同时测试 4 个节点，不会修改手动选择的节点。设置仅保存在本机。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("节点测速设置").navigationBarTitleDisplayMode(.inline)
        .task {
            url = model.delayPreferences.settings.url
            timeout = String(model.delayPreferences.settings.timeoutMilliseconds)
        }
    }
}

enum NodeDisplaySettings {
    static let iconsKey = "NativeProfiles.nodeDisplayIcons"
    static let compactKey = "NativeProfiles.nodeDisplayCompact"
}

struct ProxyDelayDisplayMenu: View {
    @ObservedObject var model: LibraryModel
    @State private var showingOptions = false

    var body: some View {
        Button { showingOptions = true } label: {
            Label("显示选项", systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityIdentifier("proxy-delay-display-options")
        .sheet(isPresented: $showingOptions) {
            NavigationStack { NodeDisplayOptionsView(model: model) }
        }
    }
}

struct NodeDisplayOptionsView: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NodeDisplaySettings.iconsKey) private var showIcons = false
    @AppStorage(NodeDisplaySettings.compactKey) private var compactRows = false

    var body: some View {
        Form {
            Section("图标") {
                Picker("图标", selection: $showIcons) {
                    Text("关闭").tag(false)
                    Text("显示").tag(true)
                }.pickerStyle(.segmented)
            }
            Section("排序") {
                Picker("排序", selection: Binding(get: { model.delayPreferences.sort }, set: {
                    var value = model.delayPreferences
                    value.sort = $0
                    model.saveDelayPreferences(value)
                })) {
                    Text("默认").tag(ProxyNodeSort.original)
                    Text("延迟").tag(ProxyNodeSort.delay)
                    Text("名称").tag(ProxyNodeSort.name)
                }.pickerStyle(.segmented)
            }
            Section("行高") {
                Picker("行高", selection: $compactRows) {
                    Text("标准").tag(false)
                    Text("紧凑").tag(true)
                }.pickerStyle(.segmented)
            }
            Section("测速") {
                Toggle("隐藏超时或失败", isOn: Binding(get: { model.delayPreferences.hideFailures }, set: {
                    var value = model.delayPreferences
                    value.hideFailures = $0
                    model.saveDelayPreferences(value)
                }))
                NavigationLink("测速设置") { ProxyDelaySettingsView(model: model) }
            }
        }
        .navigationTitle("显示选项")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("node-display-options-close")
            }
        }
    }
}
