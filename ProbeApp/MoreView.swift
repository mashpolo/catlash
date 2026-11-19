import SwiftUI

struct MoreView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel

    var body: some View {
        List {
            Section("连接行为") {
                NavigationLink { OnDemandSettingsView(model: model) } label: {
                    ClientRow(title: "按需连接", symbol: "bolt.horizontal.circle.fill", detail: model.onDemandSystemEnabled == true ? "系统按需连接已启用" : "未启用", color: .cyan)
                }
                .accessibilityIdentifier("more-ondemand")
                NavigationLink { VPNSettingsView(model: model, library: library) } label: {
                    ClientRow(title: "VPN", symbol: "shield.lefthalf.filled", detail: model.isConnected ? "已连接" : "未连接")
                }
                .accessibilityIdentifier("more-vpn")
            }
            Section("应用设置") {
                NavigationLink { ClientSettingsView(model: model, library: library) } label: {
                    ClientRow(title: "客户端设置", symbol: "slider.horizontal.3", color: .purple)
                }
                .accessibilityIdentifier("more-client")
                NavigationLink { AppearanceSettingsView() } label: {
                    ClientRow(title: "外观", symbol: "paintpalette.fill", color: .pink)
                }
                .accessibilityIdentifier("more-appearance")
            }
            Section("数据与资源") {
                NavigationLink { YAMLSyncView(model: library) } label: {
                    ClientRow(title: "iCloud 同步", symbol: "icloud.fill", detail: library.syncEnabled ? "已开启" : "未开启", color: .cyan)
                }
                .accessibilityIdentifier("more-cloud")
                NavigationLink { GeoResourcesView(model: model, library: library) } label: {
                    ClientRow(title: "Geo 资源", symbol: "globe.asia.australia.fill", color: .green)
                }
                .accessibilityIdentifier("more-geo")
                NavigationLink { StorageSpaceView(model: model, library: library) } label: {
                    ClientRow(title: "存储空间", symbol: "internaldrive.fill", color: .orange)
                }
                .accessibilityIdentifier("more-storage")
            }
            Section {
                NavigationLink { AboutClientView() } label: {
                    ClientRow(title: "关于 Catlash", symbol: "info.circle.fill")
                }
                .accessibilityIdentifier("more-about")
            }
        }
        .navigationTitle("更多")
    }
}

struct AboutClientView: View {
    @State private var copied = false
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image("BrandLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Catlash").font(.largeTitle.bold())
                    Text("iOS 原生客户端").foregroundStyle(.secondary)
                    Text("版本 \(version) · 构建 \(build)").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
                .listRowBackground(Color.clear)
            }
            Section {
                NavigationLink { VersionInformationView(version: version, build: build) } label: {
                    ClientRow(title: "版本信息", symbol: "info.circle.fill")
                }
                Link(destination: URL(string: "https://github.com/chen08209/FlClash")!) {
                    ClientRow(title: "上游项目 FlClash", symbol: "chevron.left.forwardslash.chevron.right", color: .green)
                }
                Link(destination: URL(string: "https://github.com/MetaCubeX/mihomo")!) {
                    ClientRow(title: "Mihomo 内核", symbol: "network", color: .purple)
                }
            }
            Section {
                Button {
                    UIPasteboard.general.string = "Catlash iOS \(version) (\(build))\n\(ProcessInfo.processInfo.operatingSystemVersionString)"
                    copied = true
                } label: {
                    Label(copied ? "已复制版本信息" : "复制版本信息", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
            } footer: {
                Text("SwiftUI · Mihomo\n配置文件与订阅信息仅在需要时由你导入或同步。")
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
            }
        }
        .navigationTitle("关于 Catlash").navigationBarTitleDisplayMode(.inline)
    }
}

private struct VersionInformationView: View {
    let version: String
    let build: String

    var body: some View {
        Form {
            Section("应用") {
                LabeledContent("版本", value: version)
                LabeledContent("构建", value: build)
                LabeledContent("界面", value: "SwiftUI")
                LabeledContent("内核", value: "Mihomo · Go")
            }
            Section("系统") {
                LabeledContent("系统版本", value: UIDevice.current.systemVersion)
                LabeledContent("设备", value: UIDevice.current.localizedModel)
            }
        }
        .navigationTitle("版本信息").navigationBarTitleDisplayMode(.inline)
    }
}
