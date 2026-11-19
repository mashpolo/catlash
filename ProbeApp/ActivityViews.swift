import SwiftUI

struct ActivityView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel
    @State private var section: ActivitySection = .connections
    @State private var query = ""
    @State private var logLevel = "all"
    @State private var connectionFilter = RuntimeConnectionFilter()
    @State private var confirmCloseAll = false

    private enum ActivitySection: String, CaseIterable {
        case connections = "连接", requests = "请求", logs = "日志"
    }

    var body: some View {
        List {
            Section {
                Picker("活动类型", selection: $section) {
                    ForEach(ActivitySection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                    .accessibilityIdentifier("activity-sections")
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            Section { RuntimeStatusView(model: model) }
            switch section {
            case .connections: connections
            case .requests: requests
            case .logs: logs
            }
        }
        .navigationTitle("活动")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: section == .logs ? "搜索日志" : "搜索域名、地址、规则或节点")
        .confirmationDialog("关闭本次会话的全部活动连接？", isPresented: $confirmCloseAll, titleVisibility: .visible) {
            Button("关闭全部连接", role: .destructive) { Task { await model.runtime.closeAllConnections() } }
        } message: {
            Text("也会关闭未显示的活动连接。VPN 保持连接，应用之后可以建立新连接。")
        }
    }

    private var connections: some View {
        Group {
            Section {
                HStack {
                    ToolMetric(title: "活动连接", value: model.runtime.isFresh ? String(model.runtime.snapshot?.activeCount ?? 0) : "—", symbol: "link")
                    ToolMetric(title: "实时下载", value: model.runtime.downloadRateText, symbol: "arrow.down")
                }
                Button("关闭全部活动连接", systemImage: "xmark.circle", role: .destructive) { confirmCloseAll = true }
                    .disabled(!model.runtime.isFresh || (model.runtime.snapshot?.activeCount ?? 0) == 0 || model.runtime.isClosingAllConnections)
                    .accessibilityIdentifier("runtime-close-all")
            }
            connectionFilters
            Section("TCP / UDP 连接") {
                if filteredConnections(activeOnly: true).isEmpty {
                    Text("暂无活动连接").foregroundStyle(.secondary)
                }
                connectionRows(filteredConnections(activeOnly: true))
                omittedRecords
            }
            Section("VPN 会话") {
                NavigationLink { SessionDetailView(model: model, library: library) } label: {
                    ClientRow(title: "连接详情", symbol: "shield.lefthalf.filled", detail: model.statusText, color: model.isConnected ? .green : .gray)
                }.accessibilityIdentifier("activity-connection-detail")
            }
        }
    }

    private var requests: some View {
        Group {
            connectionFilters
            Section {
                if filteredConnections(activeOnly: false).isEmpty {
                    Text("尚无请求记录").foregroundStyle(.secondary)
                }
                connectionRows(filteredConnections(activeOnly: false))
                omittedRecords
            } header: {
                Text("最近请求")
            } footer: {
                Text("按 TCP/UDP 连接记录目标、路由和结果；不解密 HTTPS 内容。记录仅保留在本次内核会话的有限缓存中。")
            }
        }
    }

    private var connectionFilters: some View {
        Section {
            DisclosureGroup("筛选与排序") {
                Picker("协议", selection: $connectionFilter.network) {
                    Text("全部").tag("")
                    Text("TCP").tag("tcp")
                    Text("UDP").tag("udp")
                }
                if section == .requests {
                    Picker("状态", selection: $connectionFilter.status) {
                        ForEach(RuntimeConnectionFilter.Status.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                TextField("域名包含", text: $connectionFilter.host)
                TextField("来源地址包含", text: $connectionFilter.source)
                TextField("目标地址包含", text: $connectionFilter.destination)
                TextField("规则包含", text: $connectionFilter.rule)
                TextField("出口节点包含", text: $connectionFilter.proxy)
                Picker("排序", selection: $connectionFilter.order) {
                    ForEach(RuntimeConnectionFilter.Order.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Button("重置筛选与排序") { connectionFilter = RuntimeConnectionFilter(); query = "" }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("runtime-connection-filters")
        }
    }

    private var logs: some View {
        Group {
            Section {
                Picker("日志级别", selection: $logLevel) {
                    Text("全部").tag("all")
                    Text("调试").tag("debug")
                    Text("信息").tag("info")
                    Text("警告").tag("warning")
                    Text("错误").tag("error")
                }
                ShareLink(item: model.runtime.exportedLogs) {
                    Label("导出运行日志", systemImage: "square.and.arrow.up")
                }
                .disabled(model.runtime.snapshot?.logs.isEmpty != false)
                .accessibilityIdentifier("runtime-export-logs")
            }
            Section("内核运行日志") {
                if filteredLogs.isEmpty { Text("尚无运行日志").foregroundStyle(.secondary) }
                ForEach(filteredLogs) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.level.uppercased()).font(.caption.weight(.semibold))
                                .foregroundStyle(entry.level == "error" ? Color.red : Color.secondary)
                            Spacer()
                            Text(RuntimeMonitor.date(entry.time), format: .dateTime.hour().minute().second())
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(entry.message).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                }
                if let dropped = model.runtime.snapshot?.droppedLogs, dropped > 0 {
                    Text("缓存已省略 \(dropped) 条较早日志。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink { DiagnosticInboxView(model: model) } label: {
                    Label("生成诊断报告", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
    }

    private var filteredLogs: [RuntimeLogEntry] {
        (model.runtime.snapshot?.logs ?? []).filter {
            (logLevel == "all" || $0.level == logLevel || (logLevel == "warning" && $0.level == "warn")) &&
                (query.isEmpty || $0.message.localizedCaseInsensitiveContains(query))
        }.reversed()
    }

    private func filteredConnections(activeOnly: Bool) -> [RuntimeConnection] {
        var filter = connectionFilter
        filter.query = query
        if activeOnly { filter.status = .active }
        return filter.apply(model.runtime.snapshot?.connections ?? [])
    }

    private func connectionRows(_ connections: [RuntimeConnection]) -> some View {
        ForEach(connections) { connection in
            NavigationLink { RuntimeConnectionDetailView(model: model, initial: connection) } label: {
                RuntimeConnectionRow(connection: connection)
            }
        }
    }

    @ViewBuilder private var omittedRecords: some View {
        if let dropped = model.runtime.snapshot?.droppedConnections, dropped > 0 {
            Text("缓存或显示数量限制已省略 \(dropped) 条连接记录，累计流量仍由内核统计。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct RuntimeStatusView: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        if let status {
            VStack(alignment: .leading, spacing: 6) {
                Text(status).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("runtime-status")
                if let snapshot = model.runtime.snapshot {
                    Text("上次更新于 \(RuntimeMonitor.date(snapshot.sampledAt).formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let message = model.runtime.actionMessage {
            Text(message).font(.footnote).textSelection(.enabled)
        }
    }

    private var status: String? {
        if !model.isConnected {
            return model.runtime.snapshot == nil ? "连接 VPN 后可查看记录。" : "VPN 已断开，显示上次记录。"
        }
        if let error = model.runtime.error { return "读取失败：\(error)" }
        if !model.runtime.isPolling { return "采样已暂停，返回前台后恢复。" }
        return model.runtime.isFresh ? nil : "正在读取内核数据…"
    }
}

private struct RuntimeConnectionRow: View {
    let connection: RuntimeConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(connection.host.isEmpty ? connection.destination : connection.host).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Text(connection.network).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text("\(connection.proxy.isEmpty ? "路由中" : connection.proxy) · \(connection.rule)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text("↑ \(RuntimeMonitor.bytes(connection.upload))  ↓ \(RuntimeMonitor.bytes(connection.download))")
                    .monospacedDigit()
                Spacer()
                Text(connection.error.isEmpty ? (connection.endedAt == 0 ? "活动中" : "已结束") : "失败")
                    .foregroundStyle(connection.error.isEmpty ? Color.secondary : Color.red)
            }.font(.caption)
        }
        .padding(.vertical, 3)
    }
}

private struct RuntimeConnectionDetailView: View {
    @ObservedObject var model: ProbeModel
    let initial: RuntimeConnection
    @State private var confirmClose = false

    private var current: RuntimeConnection? {
        model.runtime.snapshot?.connections.first { $0.id == initial.id }
    }
    private var connection: RuntimeConnection { current ?? initial }

    var body: some View {
        List {
            Section { RuntimeStatusView(model: model) }
            Section("连接") {
                LabeledContent("协议", value: connection.network)
                LabeledContent("来源", value: connection.source)
                LabeledContent("目标", value: connection.destination)
                if !connection.host.isEmpty { LabeledContent("域名", value: connection.host) }
                LabeledContent("出口", value: connection.proxy)
                LabeledContent("命中规则", value: connection.rule)
                LabeledContent("开始时间", value: RuntimeMonitor.date(connection.startedAt).formatted())
                if connection.endedAt > 0 {
                    LabeledContent("结束时间", value: RuntimeMonitor.date(connection.endedAt).formatted())
                }
                if current == nil { Text("此记录已离开当前采样窗口，显示打开详情时的数据。") }
                if !connection.error.isEmpty { Text(connection.error).foregroundStyle(.red) }
            }.textSelection(.enabled)
            Section("有效载荷") {
                LabeledContent("上传", value: RuntimeMonitor.bytes(connection.upload))
                LabeledContent("下载", value: RuntimeMonitor.bytes(connection.download))
            }
            Section {
                Button("关闭此连接", systemImage: "xmark.circle", role: .destructive) { confirmClose = true }
                    .disabled(current == nil || connection.endedAt != 0 || !model.runtime.isFresh || model.runtime.closingConnections.contains(connection.id))
            }
        }
        .navigationTitle("连接明细")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("关闭此连接？", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("关闭连接", role: .destructive) {
                Task { await model.runtime.closeConnection(connection) }
            }
        }
    }
}

struct SessionDetailView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel
    @State private var confirmDisconnect = false

    var body: some View {
        List {
            Section {
                ClientRow(title: "Catlash VPN", symbol: "shield.lefthalf.filled", detail: model.statusText, color: model.isConnected ? .green : .blue)
                LabeledContent("类型", value: "Packet Tunnel")
                LabeledContent("环境", value: ProbeModel.supportsVPN ? "iPhone" : "模拟器")
            }
            Section("策略与节点") {
                NavigationLink { NodeLibraryView(model: library, probe: model) } label: {
                    ClientRow(title: "查看节点", symbol: "point.3.connected.trianglepath.dotted")
                }
            }
            Section("本次内核会话流量") {
                HStack {
                    ToolMetric(title: "上传", value: model.runtime.uploadTotalText, symbol: "arrow.up")
                    ToolMetric(title: "下载", value: model.runtime.downloadTotalText, symbol: "arrow.down")
                }
                RuntimeStatusView(model: model)
            }
            Section {
                Button("断开 VPN", systemImage: "power", role: .destructive) { confirmDisconnect = true }
                    .disabled(!model.isConnected && !model.isStarting && !model.isConnecting)
            }
        }
        .navigationTitle("连接详情")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("断开当前 VPN？", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("断开 VPN", role: .destructive) { model.disconnect() }
        }
    }
}
