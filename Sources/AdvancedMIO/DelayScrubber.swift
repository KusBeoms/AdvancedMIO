import SwiftUI

/// Figma-style delay control (0–1000 ms).
/// - Drag on the ruler: jumps to / follows the pointer (1 ms resolution).
/// - Drag on the number: relative scrub (1 px = 1 ms, ⇧ = 10 ms, ⌥ = 0.2 ms-feel slow 1/4).
/// - Double-click: reset to 0. Trackpad haptics: tick every 10 ms, strong every 100 ms, bump at the ends.
struct DelayScrubber: View {
    @Binding var value: Double
    let range: ClosedRange<Double> = 0...AppModel.maxDelayMs

    @State private var dragStartValue: Double?
    @State private var lastValue: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            label
            ruler
        }
        .frame(height: 34)
    }

    private var label: some View {
        Text("\(Int(value)) ms")
            .font(.system(.body, design: .monospaced).weight(.medium))
            .frame(width: 78, height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStartValue == nil { dragStartValue = value }
                        let flags = NSEvent.modifierFlags
                        let scale: Double = flags.contains(.shift) ? 10 : (flags.contains(.option) ? 0.25 : 1)
                        set((dragStartValue ?? 0) + g.translation.width * scale)
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
            .onTapGesture(count: 2) { set(0) }
    }

    private var ruler: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    let color = Color.primary
                    for ms in stride(from: 0, through: 1000, by: 10) {
                        let x = CGFloat(ms) / 1000 * size.width
                        let major = ms % 100 == 0
                        let h: CGFloat = major ? 16 : (ms % 50 == 0 ? 11 : 6)
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: size.height))
                        p.addLine(to: CGPoint(x: x, y: size.height - h))
                        ctx.stroke(p, with: .color(color.opacity(major ? 0.5 : 0.25)), lineWidth: 1)
                    }
                }
                Rectangle().fill(Color.accentColor.opacity(0.18))
                    .frame(width: CGFloat(value / 1000) * w)
                Capsule().fill(Color.accentColor)
                    .frame(width: 3, height: 30)
                    .offset(x: CGFloat(value / 1000) * w - 1.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in set(Double(g.location.x / w) * 1000) }
            )
        }
    }

    private func set(_ raw: Double) {
        let v = min(range.upperBound, max(range.lowerBound, raw.rounded()))
        guard v != value else { return }
        let old = value
        value = v
        if v == range.lowerBound || v == range.upperBound {
            if old != v { Haptics.edge() }
            return
        }
        let (a, b) = (min(old, v), max(old, v))
        if Int(b / 100) != Int(a / 100) || (a.truncatingRemainder(dividingBy: 100) == 0 && a != b) {
            if Int((b / 100).rounded(.down)) > Int((a / 100).rounded(.down)) { Haptics.major(); return }
        }
        if Int(b / 10) != Int(a / 10) { Haptics.tick() }
    }
}
