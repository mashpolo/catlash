import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage("clientAppearance") private var appearance = "system"
    @AppStorage("clientAccent") private var accent = "blue"
    @AppStorage("clientTextSize") private var textSize = "system"
    @Environment(\.colorScheme) private var colorScheme
    private let themes: [(id: String, title: String)] = [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")]
    private let accents: [(id: String, title: String, color: Color)] = [
        ("blue", "蓝色", .blue), ("indigo", "靛蓝", .indigo), ("teal", "青色", .teal), ("orange", "橙色", .orange),
    ]

    var body: some View {
        Form {
            Section("主题") {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(themes, id: \.id) { theme in
                        themeOption(theme)
                    }
                }
                .padding(.vertical, 8)
            }
            Section("强调色") {
                HStack(spacing: 20) {
                    ForEach(accents, id: \.id) { option in
                        Button { accent = option.id } label: {
                            Image(systemName: "checkmark")
                                .font(.headline).foregroundStyle(.white)
                                .opacity(accent == option.id ? 1 : 0)
                                .frame(width: 44, height: 44)
                                .background(option.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(accent == option.id ? .isSelected : [])
                        .accessibilityIdentifier("appearance-accent-" + option.id)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Section {
                Picker("文字大小", selection: $textSize) {
                    Text("跟随系统").tag("system")
                    Text("较大").tag("large")
                }
                .accessibilityIdentifier("appearance-text-size")
                LabeledContent("语言", value: "简体中文")
                LabeledContent("减少动画", value: "跟随系统")
                LabeledContent("对比度", value: "跟随系统")
            } footer: {
                Text("主题、强调色与文字大小立即应用，并保存在本机。辅助功能跟随 iOS 系统设置。")
            }
            Section("界面预览") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Catlash", systemImage: "shield.lefthalf.filled").font(.headline)
                        Text("让连接更简单").foregroundStyle(.secondary)
                        Text("规则 · 全局 · 直连").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "power")
                        .font(.title2.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(selectedAccent, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("外观").navigationBarTitleDisplayMode(.inline)
    }

    private var selectedAccent: Color { accents.first { $0.id == accent }?.color ?? .blue }

    private func themeOption(_ theme: (id: String, title: String)) -> some View {
        let dark = theme.id == "dark" || (theme.id == "system" && colorScheme == .dark)
        return Button { appearance = theme.id } label: {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(dark ? Color.white.opacity(0.8) : Color.black.opacity(0.7))
                        .frame(width: 24, height: 4).frame(maxWidth: .infinity)
                    Text("Catlash").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(dark ? .white : .black)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selectedAccent.opacity(0.15)).frame(height: 22)
                    Image(systemName: "power").font(.title3.weight(.bold)).foregroundStyle(selectedAccent)
                        .frame(maxWidth: .infinity)
                }
                .padding(10).frame(maxWidth: .infinity)
                .background(dark ? Color(white: 0.14) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(appearance == theme.id ? selectedAccent : Color.secondary.opacity(0.15), lineWidth: appearance == theme.id ? 2 : 1)
                }
                Label(theme.title, systemImage: appearance == theme.id ? "checkmark.circle.fill" : "circle")
                    .font(.caption).foregroundStyle(appearance == theme.id ? selectedAccent : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(appearance == theme.id ? .isSelected : [])
        .accessibilityIdentifier("appearance-" + theme.id)
    }
}
