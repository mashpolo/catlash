import SwiftUI

struct DNSOverrideSettingsView: View {
    @ObservedObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DNSOverridePreferences
    @State private var saving = false
    @State private var errorMessage: String?

    init(library: LibraryModel) {
        self.library = library
        _draft = State(initialValue: library.dnsPreferences)
    }

    var body: some View {
        Form {
            Section {
                Toggle("追加系统 DNS", isOn: $draft.appendSystemDNS)
                    .accessibilityIdentifier("dns-append-system")
            } footer: {
                Text("将当前网络的 DNS 加入 nameserver，与配置中的上游一起使用。")
            }
            OverrideFieldsSection(title: "DNS 覆盖项", keys: Self.dnsKeys, fields: $draft.dns)
            OverrideFieldsSection(title: "TUN 覆盖项", keys: ["dns-hijack", "route-exclude-address"], fields: $draft.tun)
        }
        .disabled(saving)
        .navigationTitle("DNS 与 TUN 覆盖")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    saving = true
                    Task {
                        do {
                            try await library.saveDNSPreferences(draft)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        saving = false
                    }
                }
                .disabled(saving || draft == library.dnsPreferences)
                .accessibilityIdentifier("dns-overrides-save")
            }
        }
        .alert("无法保存 DNS 或 TUN 设置", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private static let dnsKeys = [
        "nameserver", "default-nameserver", "proxy-server-nameserver", "direct-nameserver",
        "fallback", "enhanced-mode", "ipv6", "enable", "nameserver-policy",
        "proxy-server-nameserver-policy", "direct-nameserver-follow-policy", "respect-rules",
        "fallback-filter", "fallback-lazy-query", "fake-ip-range", "fake-ip-range6",
        "fake-ip-filter", "fake-ip-filter-mode", "fake-ip-ttl", "ipv6-timeout", "prefer-h3",
        "use-hosts", "use-system-hosts", "cache-algorithm", "cache-max-size"
    ]
}

private struct OverrideFieldsSection: View {
    let title: String
    let keys: [String]
    @Binding var fields: [String: DNSOverridePreferences.Field]

    var body: some View {
        Section(title) {
            ForEach(fields.keys.sorted(), id: \.self) { key in
                let field = Binding(
                    get: { fields[key] ?? .init(enabled: false, value: "") },
                    set: { fields[key] = $0 }
                )
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(key, isOn: field.enabled)
                    if field.wrappedValue.enabled {
                        TextField("YAML 值", text: field.value, axis: .vertical)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(1...10)
                            .accessibilityLabel("\(key) 的 YAML 值")
                    }
                }
            }
            .onDelete { offsets in
                let currentKeys = fields.keys.sorted()
                for offset in offsets { fields.removeValue(forKey: currentKeys[offset]) }
            }
            let available = keys.filter { fields[$0] == nil }
            if !available.isEmpty {
                Menu {
                    ForEach(available, id: \.self) { key in
                        Button(key) { fields[key] = .init(enabled: true, value: "") }
                    }
                } label: {
                    Label("添加覆盖项", systemImage: "plus")
                }
                .accessibilityLabel("添加\(title)")
            }
        }
    }
}
