import SwiftUI

struct SubscriptionProfileSection: View {
    @ObservedObject var model: LibraryModel
    let profile: ProfileRecord
    let url: URL

    var body: some View {
        Section("订阅") {
            LabeledContent("服务器", value: url.host ?? "未知")
            if let usage = profile.subscription?.usage {
                LabeledContent("上传流量", value: subscriptionBytes(usage.upload))
                LabeledContent("下载流量", value: subscriptionBytes(usage.download))
                LabeledContent("流量总额", value: subscriptionBytes(usage.total))
                LabeledContent("到期时间", value: usage.expiresAt?.formatted(date: .abbreviated, time: .shortened) ?? "未提供")
                    .foregroundStyle(usage.expiresAt.map { $0 < Date() } == true ? .red : .primary)
            } else {
                Text("订阅服务器尚未提供流量与到期信息。").font(.footnote).foregroundStyle(.secondary)
            }
            if let checkedAt = profile.subscription?.checkedAt {
                LabeledContent("上次检查", value: checkedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Picker("自动更新间隔", selection: Binding(
                get: { profile.subscription?.interval ?? 0 },
                set: { value in Task { await model.setSubscriptionInterval(value == 0 ? nil : value, profileID: profile.id) } }
            )) {
                Text("关闭").tag(TimeInterval(0))
                Text("1 小时").tag(TimeInterval(3600))
                Text("6 小时").tag(TimeInterval(21600))
                Text("12 小时").tag(TimeInterval(43200))
                Text("24 小时").tag(TimeInterval(86400))
                Text("3 天").tag(TimeInterval(259200))
            }.disabled(model.busy || model.downloading)
                .accessibilityIdentifier("subscriptionUpdateInterval")
            Button("更新订阅", systemImage: "arrow.clockwise") {
                model.downloadSubscription(url: url, name: profile.displayName, replacing: profile)
            }.disabled(model.downloading || model.busy)
            if let result = model.subscriptionUpdates.first(where: { $0.id == profile.id }) {
                SubscriptionUpdateStatusView(result: result)
            }
            if model.downloading {
                Button("取消订阅更新") { model.cancelDownload() }
            }
            Text("流量和到期信息来自订阅服务器。应用在前台定时检查订阅。当前配置更新后，已连接的 VPN 会自动重连。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct SubscriptionUsageSummary: View {
    let usage: SubscriptionUsage

    var body: some View {
        Text("上传 \(subscriptionBytes(usage.upload)) · 下载 \(subscriptionBytes(usage.download))")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct SubscriptionUpdateResultsView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        if model.downloading || !model.subscriptionUpdates.isEmpty {
            Section("订阅更新") {
                ForEach(model.subscriptionUpdates) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.name)
                        SubscriptionUpdateStatusView(result: result)
                    }
                }
                if model.downloading {
                    HStack {
                        ProgressView()
                        Text(model.subscriptionUpdates.isEmpty ? "正在导入订阅" : "正在更新订阅")
                        Spacer()
                        Button("取消") { model.cancelDownload() }
                    }
                }
            }
        }
    }
}

private struct SubscriptionUpdateStatusView: View {
    let result: SubscriptionUpdateResult

    var body: some View {
        switch result.status {
        case .pending: Text("等待更新").font(.caption).foregroundStyle(.secondary)
        case .updating: Text("正在下载与校验").font(.caption).foregroundStyle(.secondary)
        case .updated: Label("已更新", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
        case .cancelled: Text("已取消").font(.caption).foregroundStyle(.secondary)
        case .failed(let reason): Text("更新失败：\(reason)").font(.caption).foregroundStyle(.red)
        }
    }
}

private func subscriptionBytes(_ bytes: Int64?) -> String {
    bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未提供"
}
