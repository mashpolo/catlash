import SwiftUI

struct ToolsView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel

    var body: some View {
        List {
            Section("本次连接") {
                NavigationLink { ActivityView(model: model, library: library) } label: {
                    ClientRow(title: "活动", symbol: "waveform.path.ecg", detail: "连接、请求与日志", color: .cyan)
                }.accessibilityIdentifier("tools-activity")
                NavigationLink { DNSHistoryView(model: model) } label: {
                    ClientRow(title: "DNS 历史", symbol: "clock.arrow.circlepath", detail: "内核查询、响应与解析缓存", color: .cyan)
                }.accessibilityIdentifier("tools-dns-history")
            }
            Section("网络工具") {
                NavigationLink { NetworkQualityView(model: model, library: library) } label: {
                    ClientRow(title: "网络质量", symbol: "speedometer", color: .blue)
                }.accessibilityIdentifier("tools-quality")
                NavigationLink { STUNView(model: model) } label: {
                    ClientRow(title: "STUN 与 NAT", symbol: "point.3.connected.trianglepath.dotted", color: .purple)
                }.accessibilityIdentifier("tools-stun")
                NavigationLink { DNSQueryView(model: model) } label: {
                    ClientRow(title: "DNS 查询", symbol: "network", color: .cyan)
                }.accessibilityIdentifier("tools-dns")
                NavigationLink { ProxySharingView(model: model) } label: {
                    ClientRow(title: "局域网代理共享", symbol: "antenna.radiowaves.left.and.right", color: .blue)
                }.accessibilityIdentifier("tools-sharing")
            }
            Section("运行状况与报告") {
                NavigationLink { RuntimeHealthView(model: model, library: library) } label: {
                    ClientRow(title: "运行状况", symbol: "heart.text.clipboard", detail: model.statusText, color: .green)
                }.accessibilityIdentifier("tools-runtime")
                NavigationLink { ExternalResourcesView(model: library, probe: model) } label: {
                    ClientRow(title: "外部资源", symbol: "externaldrive", color: .purple)
                }.accessibilityIdentifier("tools-resources")
                NavigationLink { DiagnosticInboxView(model: model) } label: {
                    ClientRow(title: "诊断收件箱", symbol: "tray", color: .orange)
                }.accessibilityIdentifier("tools-reports")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("工具")
    }
}
