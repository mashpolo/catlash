import SwiftUI

struct RemoteResourcesSection: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel
    @State private var catalog: RunningProviderCatalog?
    private var providers: [RuntimeProviderSummary] { catalog?.entries ?? [] }
    @State private var loading = false
    @State private var updating: String?
    @State private var error: String?
    @State private var refresh = UUID()

    private var externalUpdateRunning: Bool {
        model.isConnected && library.resourceRefreshRunning && updating == nil
    }

    private var sessionKey: String {
        "\(model.isConnected)-\(model.connectionGeneration)-\(model.runtime.snapshot?.sessionID ?? "")-\(refresh)"
    }

    var body: some View {
        Section {
            LabeledContent("运行配置", value: runtimeProfileName)
            if !model.isConnected {
                Text("连接 VPN 后查看远程资源的实际加载状态并更新单项资源。")
                    .foregroundStyle(.secondary).accessibilityIdentifier("remote-resources-offline")
            } else {
                if externalUpdateRunning {
                    ProgressView("正在更新远程资源…").accessibilityIdentifier("remote-resources-background-update")
                }
                if loading { ProgressView("正在读取远程资源…") }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("remote-resources-error")
                }
                if providers.isEmpty && !loading && error == nil {
                    Text("当前运行配置没有远程节点或规则来源。")
                        .foregroundStyle(.secondary).accessibilityIdentifier("remote-resources-empty")
                }
                ForEach(providers, id: \.resourceID) { provider in
                    providerRow(provider)
                }
                if providers.contains(where: \.canRefresh) {
                    Button("更新全部远程资源", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await update(nil) }
                    }
                    .disabled(loading || library.resourceRefreshRunning || updating != nil)
                    .accessibilityIdentifier("remote-resources-update-all")
                }
                Button("刷新资源状态", systemImage: "arrow.clockwise") { refresh = UUID() }
                    .disabled(loading || updating != nil)
                    .accessibilityIdentifier("remote-resources-refresh")
            }
        } header: {
            Text("运行中的资源")
        } footer: {
            if updating == "all" {
                ProgressView("正在更新远程资源…").accessibilityIdentifier("remote-resources-operation")
            }
        }
        .task(id: sessionKey) { await load() }
        .onChange(of: externalUpdateRunning) { wasRunning, running in
            if wasRunning, !running, model.isConnected, updating == nil { refresh = UUID() }
        }
    }

    private var runtimeProfileName: String {
        guard model.isConnected else { return "VPN 未连接" }
        return library.profiles.first { $0.id == model.activeRuntimeProfileID }?.displayName ?? "正在读取…"
    }

    private func providerRow(_ provider: RuntimeProviderSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label(provider.name, systemImage: provider.kind == .proxyProvider ? "server.rack" : "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                if provider.canRefresh {
                    Button {
                        Task { await update(provider) }
                    } label: {
                        Group {
                            if updating == provider.resourceID { ProgressView() }
                            else { Image(systemName: "arrow.clockwise") }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(updating != nil || library.resourceRefreshRunning || loading || catalog == nil)
                    .accessibilityLabel("更新 " + provider.name)
                    .accessibilityIdentifier("remote-resource-update-" + provider.resourceID)
                }
            }
            Text(providerSummary(provider)).font(.subheadline).foregroundStyle(.secondary)
            Text(provider.status == "ready" ? "已加载" : "等待加载")
                .font(.caption).foregroundStyle(provider.status == "ready" ? Color.green : Color.secondary)
            if let date = provider.updatedAt {
                Text("更新时间 \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let usage = provider.subscription {
                Text("上传 \(byteCount(usage.upload)) · 下载 \(byteCount(usage.download))")
                    .font(.caption).foregroundStyle(.secondary)
                if let total = usage.total {
                    Text("总额度 " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let expiry = usage.expiresAt {
                    Text("到期 \(expiry.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("remote-resource-" + provider.resourceID)
    }

    private func byteCount(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知"
    }

    private func providerSummary(_ provider: RuntimeProviderSummary) -> String {
        let kind = provider.kind == .proxyProvider ? "节点" : "规则"
        let count = provider.count.map { "\($0) 个\(kind)" } ?? "\(kind)数量待加载"
        return count + " · " + provider.source.uppercased()
    }

    @MainActor private func load() async {
        catalog = nil
        error = nil
        updating = nil
        loading = model.isConnected
        guard model.isConnected else { return }
        let key = sessionKey
        defer { if key == sessionKey { loading = false } }
        do { try await readCatalog(key: key) }
        catch is CancellationError {}
        catch { if key == sessionKey { self.error = error.localizedDescription } }
    }

    @MainActor private func readCatalog(key: String) async throws {
        let result = try await library.runningProviders(using: model)
        try Task.checkCancellation()
        guard key == sessionKey else { throw CancellationError() }
        catalog = result
    }

    @MainActor private func update(_ provider: RuntimeProviderSummary?) async {
        guard let catalog, updating == nil else { return }
        let key = sessionKey
        updating = provider?.resourceID ?? "all"
        error = nil
        defer { if key == sessionKey { updating = nil } }
        do {
            let result = try await library.updateRunningProviders(provider.map { [$0] } ?? catalog.entries,
                                                                 in: catalog, using: model)
            guard key == sessionKey else { return }
            self.catalog = result
            await library.refreshCatalog(using: model)
        } catch is CancellationError {
        } catch {
            guard key == sessionKey else { return }
            self.error = error.localizedDescription
            try? await readCatalog(key: key)
        }
    }
}

private extension RuntimeProviderSummary {
    var resourceID: String { kind.rawValue + ":" + name }
}
