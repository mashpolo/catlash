import SwiftUI

struct ExitIPDetailView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideExitIP") private var hideExitIP = false

    var body: some View {
        List {
            Section("当前出口") {
                if let result = model.exitIP.result {
                    LabeledContent(result.addressFamily, value: hideExitIP ? "*****" : result.ip)
                        .textSelection(.enabled)
                        .foregroundStyle(result.qualityDetails?.level.color ?? .primary)
                    LabeledContent("地区", value: result.countryCode ?? "未知")
                    LabeledContent("类型", value: result.networkType)
                    LabeledContent("质量", value: result.quality)
                        .foregroundStyle(result.qualityDetails?.level.color ?? .primary)
                    if let quality = result.qualityDetails {
                        LabeledContent("标记", value: quality.flags.isEmpty ? "无" : quality.flags.joined(separator: " · "))
                    }
                    Text(result.qualityExplanation).font(.footnote).foregroundStyle(.secondary)
                    ShareLink("分享 IP", item: result.ip)
                } else if model.exitIP.isLoading {
                    ProgressView("正在查询实际出口与质量…")
                    ForEach(["类型", "质量", "标记"], id: \.self) { title in
                        LabeledContent(title, value: "正在检测…").foregroundStyle(.secondary)
                    }
                } else {
                    Text(model.exitIP.error ?? "连接后可检测出口 IP。")
                        .foregroundStyle(.secondary)
                }
                if model.isConnected, let global = library.activeGlobalGroup,
                   model.exitIP.error != nil || (model.exitIP.result?.failures.isEmpty == false && model.exitIP.result?.qualityDetails == nil) {
                    NavigationLink {
                        NodeLibraryView(model: library, probe: model, title: "选择全局节点", initiallyExpandedGroup: global.name)
                    } label: {
                        LabeledContent("选择全局节点", value: global.now ?? global.name)
                    }
                    .accessibilityIdentifier("ip-quality-global-node")
                }
                Button("重新检测") { model.refreshExitIP(forceRefresh: true) }
                    .disabled(!model.isConnected || model.exitIP.isLoading)
                    .accessibilityIdentifier("ip-quality-refresh")
            }
            if let result = model.exitIP.result {
                Section("网络与来源") {
                    LabeledContent("组织", value: result.organization ?? "未知")
                    LabeledContent("ASN", value: result.qualityDetails?.asn.map { "AS\($0)" } ?? "—")
                    if let quality = result.qualityDetails {
                        LabeledContent("数据来源", value: quality.source.label)
                        if quality.inferred { LabeledContent("判定方式", value: "推断住宅") }
                    }
                    if let checkedAt = result.checkedAt {
                        LabeledContent("检测时间", value: checkedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    if result.cached {
                        Text(result.qualityDetails == nil ? "暂时复用本次 IP 的失败结果，可点重新检测立即重试。" : "使用本次 IP 的缓存分类，可点重新检测更新。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if result.qualityDetails == nil, !result.failures.isEmpty {
                    Section("来源检测结果") {
                        ForEach(result.failures.indices, id: \.self) { index in
                            LabeledContent(result.failures[index].source.label, value: result.failures[index].status.label)
                        }
                    }
                }
            }
            Section("显示") {
                Toggle("隐藏 IP 地址", isOn: $hideExitIP)
                    .accessibilityIdentifier("hide-exit-ip")
            }
            Section("检测说明") {
                Link("IP 地址：ipify", destination: URL(string: "https://www.ipify.org")!)
                Link("备用 IP 地址来源：IPIP.NET", destination: URL(string: "https://myip.ipip.net")!)
                Text("质量来源依次分批查询 ident.me、ip-api.com、IPQuery、IPLocate、ipapi.is 和 proxycheck.io；优先采用明确的网络类型。成功分类缓存 3 天，全部失败后暂停自动重试 5 分钟。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("查询经当前内核的规则或全局出口发送，优先通过 ipify 检测 IPv4，再检测 IPv6；均失败后使用 IPIP.NET 返回的公网地址。显示检测请求实际使用的公网地址，不同目标可能使用不同出口。切换模式或节点后重新确认 IP。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("出口 IP 与质量")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}

extension IPQualityLevel {
    var color: Color {
        switch self {
        case .good: return .green
        case .normal: return .primary
        case .risky: return .red
        }
    }
}
