import SwiftUI

@main
struct ProbeApp: App {
    @StateObject private var model = ProbeModel()
    @StateObject private var library = LibraryModel()
    @AppStorage("clientAppearance") private var appearance = "system"
    @AppStorage("clientAccent") private var accent = "blue"
    @AppStorage("clientTextSize") private var textSize = "system"
    @Environment(\.dynamicTypeSize) private var systemTextSize

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { HomeView(model: model, library: library) }
                    .tabItem { Label("首页", systemImage: "house.fill") }
                NavigationStack { NodeLibraryView(model: library, probe: model) }
                    .tabItem { Label("节点", systemImage: "network") }
                NavigationStack { ToolsView(model: model, library: library) }
                    .tabItem { Label("工具", systemImage: "briefcase") }
                NavigationStack { MoreView(model: model, library: library) }
                    .tabItem { Label("更多", systemImage: "ellipsis.circle") }
            }
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
            .tint(ClientPalette.accent(accent))
            .environment(\.dynamicTypeSize, textSize == "large" ? max(systemTextSize, .xLarge) : systemTextSize)
            .task {
                await model.restore()
                await library.load()
                library.setForeground(UIApplication.shared.applicationState == .active, using: model)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                library.setForeground(true, using: model)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                library.setForeground(false, using: model)
            }
        }
    }
}

struct ConnectionView: View {
    @ObservedObject var model: ProbeModel
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case server, port, username, password }

    var body: some View {
                Form {
                    Section("连接状态") {
                        Text("此诊断用于检查扩展的基础连通性。日常使用请从首页连接所选配置。")
                        Text("基础诊断仅接管发往 1.1.1.1 的 IPv4 流量。启动时会自动准备测试配置。")
                            .font(.footnote)
                        LabeledContent("VPN 状态", value: model.statusText)
                    }
                    Section("基础诊断设置") {
                        if !ProbeModel.supportsVPN {
                            Text("系统 VPN 与基础连接诊断需要在真机运行。")
                                .font(.footnote)
                        }
                        Toggle("使用 SOCKS5 出站", isOn: $model.useSOCKS5)
                        if model.useSOCKS5 {
                            TextField("服务器", text: $model.server)
                                .focused($focusedField, equals: .server)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("端口", text: $model.port).keyboardType(.numberPad)
                                .focused($focusedField, equals: .port)
                            TextField("用户名（可选）", text: $model.username)
                                .focused($focusedField, equals: .username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("密码（可选）", text: $model.password)
                                .focused($focusedField, equals: .password)
                        }
                    }
                    Section {
                        Button("启动测试 VPN") { model.startDiagnostic() }
                            .disabled(!ProbeModel.supportsVPN || model.isPreparingSnapshot || (model.isStarting || model.isConnecting) || model.isConnected)
                        Button("停止测试 VPN") { model.disconnect() }
                            .disabled(!ProbeModel.supportsVPN)
                        Button("通过测试隧道查询 example.com") { model.probe() }
                            .disabled(!model.isConnected || model.isProbing)
                    }
                    Section("结果") {
                        Text(model.message).textSelection(.enabled)
                        NavigationLink("诊断与内存", destination: DiagnosticView(model: model))
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成") { focusedField = nil }
                    }
                }
                .navigationTitle("基础连接诊断")
                .navigationBarTitleDisplayMode(.inline)
    }
}
