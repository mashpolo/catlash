import SwiftUI

enum ClientPalette {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardRadius: CGFloat = 24

    static func accent(_ value: String) -> Color {
        switch value {
        case "indigo": .indigo
        case "teal": .teal
        case "orange": .orange
        default: .blue
        }
    }
}

struct ClientCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClientPalette.surface, in: RoundedRectangle(cornerRadius: ClientPalette.cardRadius, style: .continuous))
    }
}

struct ClientRow: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    var color: Color = .blue

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct ClientNotice: View {
    let title: String
    let message: String
    var symbol: String = "info.circle"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

struct ConnectionFlower: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return Path { path in
            for step in 0...240 {
                let angle = Double(step) / 240 * .pi * 2
                let edge = radius * (0.94 + 0.06 * cos(angle * 8))
                let point = CGPoint(x: center.x + edge * cos(angle), y: center.y + edge * sin(angle))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}
