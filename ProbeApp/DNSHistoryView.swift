import SwiftUI

struct DNSHistoryView: View {
    @ObservedObject var model: ProbeModel
    @State private var filter = RuntimeDNSFilter()

    private var queries: [RuntimeDNSQuery] { model.runtime.snapshot?.dnsQueries ?? [] }
    private var visible: [RuntimeDNSQuery] { filter.apply(queries) }

    var body: some View {
        List {
            Section { RuntimeStatusView(model: model) }
            Section {
                TextField("搜索域名、上游或响应", text: $filter.query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("dns-history-search")
                DisclosureGroup("筛选与排序") {
                    Picker("记录类型", selection: $filter.type) {
                        Text("全部").tag("")
                        ForEach(Array(Set(queries.map(\.type))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("结果", selection: $filter.status) {
                        Text("全部").tag("")
                        Text("成功").tag("success")
                        Text("失败").tag("failed")
                        Text("超时").tag("timeout")
                        Text("已取消").tag("cancelled")
                    }
                    Picker("缓存", selection: $filter.cache) {
                        ForEach(RuntimeDNSFilter.Cache.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("来源", selection: $filter.initiator) {
                        Text("全部").tag("")
                        ForEach(Array(Set(queries.map(\.initiator))).sorted(), id: \.self) { Text($0.isEmpty ? "未知" : $0).tag($0) }
                    }
                    Picker("处理方式", selection: $filter.mode) {
                        Text("全部").tag("")
                        Text("解析器").tag("resolver")
                        Text("Hosts").tag("hosts")
                        Text("Fake-IP").tag("fakeip")
                        Text("IPv6 解析未启用").tag("disabled-ipv6")
                    }
                    Picker("排序", selection: $filter.order) {
                        ForEach(RuntimeDNSFilter.Order.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Button("重置筛选与排序") { filter = RuntimeDNSFilter() }
                }.accessibilityIdentifier("dns-history-filters")
                Button("清除内核解析缓存", systemImage: "trash") { Task { await model.runtime.clearDNSCache() } }
                    .disabled(!model.runtime.isFresh || model.runtime.snapshot?.dnsQueries == nil || model.runtime.isClearingDNSCache)
                    .accessibilityIdentifier("dns-history-clear-cache")
            } footer: {
                Text("清缓存保留查询历史和 Fake-IP 映射，避免影响已有连接。清除后，正在进行的查询仍可写入新的解析结果。")
            }
            Section {
                if visible.isEmpty {
                    Text(queries.isEmpty ? "尚无本次内核会话的 DNS 查询记录。" : "没有符合筛选条件的记录。")
                        .foregroundStyle(.secondary).accessibilityIdentifier("dns-history-empty")
                }
                ForEach(visible) { query in
                    NavigationLink { DNSHistoryDetailView(model: model, query: query) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(query.domain).font(.headline).lineLimit(1)
                                Spacer()
                                Text(query.type).font(.caption.weight(.semibold))
                            }
                            HStack {
                                Text("\(query.modeText) · \(query.statusText)")
                                Spacer()
                                Text("\(query.durationMS) ms").monospacedDigit()
                            }.font(.caption).foregroundStyle(.secondary)
                            Text(RuntimeMonitor.date(query.startedAt), format: .dateTime.hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
                if let dropped = model.runtime.snapshot?.droppedDNSQueries, dropped > 0 {
                    Text("缓存或响应大小限制已省略 \(dropped) 条较早查询。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("查询记录 · \(visible.count) / \(queries.count)")
            } footer: {
                Text("记录内核完成的解析、缓存命中及 Hosts/Fake-IP 响应；并发合并的解析可能仅记录一次。最多保留本次会话的 200 条记录，每条最多显示 8 项限长响应。")
            }
        }
        .navigationTitle("DNS 历史")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DNSHistoryDetailView: View {
    @ObservedObject var model: ProbeModel
    let query: RuntimeDNSQuery

    var body: some View {
        List {
            Section { RuntimeStatusView(model: model) }
            Section("查询") {
                LabeledContent("域名", value: query.domain)
                LabeledContent("类型", value: query.type)
                LabeledContent("来源", value: query.initiator.isEmpty ? "未知" : query.initiator)
                LabeledContent("时间", value: RuntimeMonitor.date(query.startedAt).formatted())
                LabeledContent("耗时", value: "\(query.durationMS) ms")
                LabeledContent("结果", value: query.statusText)
                LabeledContent("处理方式", value: query.modeText)
                LabeledContent("缓存命中", value: query.cached ? "是" : "否")
                if !query.responseCode.isEmpty { LabeledContent("响应码", value: query.responseCode) }
                if !query.upstream.isEmpty { LabeledContent("上游", value: query.upstream) }
            }.textSelection(.enabled)
            Section("响应记录") {
                if query.answers.isEmpty { Text("无响应记录").foregroundStyle(.secondary) }
                ForEach(Array(query.answers.enumerated()), id: \.offset) { _, answer in
                    Text(answer).font(.callout.monospaced()).textSelection(.enabled)
                }
                if query.omittedAnswers > 0 { Text("另有 \(query.omittedAnswers) 项未显示。") }
            }
            if model.runtime.snapshot?.dnsQueries?.contains(where: { $0.id == query.id }) != true {
                Section { Text("此记录已离开当前采样窗口，显示打开详情时的数据。").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("DNS 查询详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}
