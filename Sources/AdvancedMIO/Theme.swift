import AppKit
import SwiftUI

/// SF Symbol drawn through NSImage (template-tinted by `foregroundStyle`). Falls back to `Image(systemName:)`.
struct Symbol: View {
    let name: String
    var size: CGFloat = 14
    var weight: NSFont.Weight = .semibold

    init(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .semibold) {
        self.name = name; self.size = size; self.weight = weight
    }

    var body: some View {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)) {
            Image(nsImage: img).renderingMode(.template)
        } else {
            Image(systemName: name).font(.system(size: size, weight: .semibold))
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255, opacity: opacity)
    }
}

enum Theme {
    static let violet = Color(hex: 0x7C5CFF)
    static let cyan = Color(hex: 0x19D3FF)
    static let pink = Color(hex: 0xFF5C93)
    static let accent = LinearGradient(colors: [violet, cyan], startPoint: .leading, endPoint: .trailing)
    static let accentDiagonal = LinearGradient(colors: [violet, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let text2 = Color.white.opacity(0.55)
    static let text3 = Color.white.opacity(0.35)
}

struct CardStyle: ViewModifier {
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(highlighted ? 0.075 : 0.045)))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(highlighted ? AnyShapeStyle(Theme.accent.opacity(0.55)) : AnyShapeStyle(Color.white.opacity(0.08)),
                                  lineWidth: 1))
    }
}

extension View {
    func card(highlighted: Bool = false) -> some View { modifier(CardStyle(highlighted: highlighted)) }
}

struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(hex: 0x0B0C16)
            Circle().fill(Theme.violet.opacity(0.28)).frame(width: 520).blur(radius: 120).offset(x: -300, y: -260)
            Circle().fill(Theme.cyan.opacity(0.16)).frame(width: 460).blur(radius: 120).offset(x: 340, y: 300)
        }
        .ignoresSafeArea()
    }
}

struct IconBadge: View {
    let symbol: String
    var active: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(active ? AnyShapeStyle(Theme.accentDiagonal) : AnyShapeStyle(Color.white.opacity(0.08)))
            Symbol(symbol, size: 16)
                .foregroundStyle(active ? .white : Theme.text2)
        }
        .frame(width: 38, height: 38)
    }
}
