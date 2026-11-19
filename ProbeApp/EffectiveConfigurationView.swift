import SwiftUI

struct EffectiveConfigurationView: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject var library: LibraryModel
    @State private var text = ""
    @State private var loading = false
    @State private var error: String?
    @State private var refresh = UUID()

    private var sessionKey: String {
        "\(model.isConnected)-\(model.connectionGeneration)-\(model.runtime.snapshot?.sessionID ?? "")-\(refresh)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.isConnected {
                    ContentUnavailableView("VPN 未连接", systemImage: "network", description: Text("连接后可查看内核当前实际使用的配置。"))
                        .accessibilityIdentifier("effective-configuration-offline")
                } else {
                    Text(runtimeProfileName).font(.headline)
                    Text("当前内核配置，敏感字段已隐藏。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if loading { ProgressView("正在读取有效配置…") }
                    if let error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityIdentifier("effective-configuration-error")
                    }
                    if !text.isEmpty {
                        Text(text).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("effective-configuration-yaml")
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("有效配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("刷新", systemImage: "arrow.clockwise") { refresh = UUID() }
                .disabled(!model.isConnected || loading)
                .accessibilityIdentifier("effective-configuration-refresh")
        }
        .task(id: sessionKey) { await load() }
    }

    private var runtimeProfileName: String {
        library.profiles.first { $0.id == model.activeRuntimeProfileID }?.displayName ?? "当前运行配置"
    }

    @MainActor private func load() async {
        text = ""
        error = nil
        loading = model.isConnected
        guard model.isConnected else { return }
        let key = sessionKey
        defer { if key == sessionKey { loading = false } }
        do {
            var data = Data()
            var offset = 0
            var session: String?
            repeat {
                let reply = try await model.control(.init(action: .effectiveConfiguration, expectedSessionID: session, offset: offset))
                try Task.checkCancellation()
                guard key == sessionKey else { return }
                if let failure = reply.error { throw ConfigurationReadError.message(failure) }
                guard let page = reply.configurationPage else { throw ConfigurationReadError.message("内核未返回有效配置，请重新读取。") }
                if let session, session != page.sessionID { throw CancellationError() }
                session = page.sessionID
                data.append(page.data)
                guard data.count <= 16 * 1024 * 1024 else { throw ConfigurationReadError.message("有效配置超过 16 MiB，无法在此页面完整显示。") }
                guard let next = page.nextOffset else { break }
                guard next > offset else { throw ConfigurationReadError.message("有效配置分页响应无效。") }
                offset = next
            } while true
            guard let decoded = String(data: data, encoding: .utf8) else { throw ConfigurationReadError.message("有效配置不是有效的 UTF-8 文本。") }
            text = decoded
        } catch is CancellationError {
        } catch {
            if key == sessionKey { self.error = error.localizedDescription }
        }
    }
}

private enum ConfigurationReadError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case let .message(text): return text }
    }
}
