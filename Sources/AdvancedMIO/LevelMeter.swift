import SwiftUI

/// Thin peak meter (−60…0 dBFS) with fast attack and smooth release. `source` is polled at ~30 fps.
struct LevelMeter: View {
    let source: () -> Float
    var height: CGFloat = 4

    private final class Box { var value: CGFloat = 0 }
    @State private var box = Box()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let raw = CGFloat(source())
            let db = raw > 0.000_001 ? 20 * log10(raw) : -90
            let target = max(0, min(1, (db + 60) / 60))
            let _ = { box.value = target > box.value ? target : max(target, box.value - 0.04) }()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: 0x3DDC97), Color(hex: 0xFFD166), Color(hex: 0xFF5C5C)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, geo.size.width * box.value))
                        .mask(Capsule())
                        .opacity(box.value > 0.001 ? 1 : 0.0)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
