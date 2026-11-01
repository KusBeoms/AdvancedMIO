import AppKit
import MIOCore
import SwiftUI

/// Figma-style delay control, 0–1000 ms.
///  • Drag the ruler → the playhead follows the pointer (1 ms steps).
///  • Drag the number → relative scrub, like Figma's numeric fields (⇧ ×10, ⌥ ×¼).
///  • Double-click the number → reset to 0.
/// Trackpad haptics: light tick every 10 ms, strong tick every 100 ms, bump at both ends.
struct DelayScrubber: View {
    let value: Double
    let onChange: (Double) -> Void
    var enabled = true
    var forceBubble = false          // screenshots only

    private let maxValue = DelayReader.maxDelayMs
    @State private var draggingState = false
    private var dragging: Bool { draggingState || forceBubble }
    @State private var scrubStart: Double?
    @State private var hoverNumber = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ruler
        }
        .opacity(enabled ? 1 : 0.4)
        .allowsHitTesting(enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("출력 지연")
        .accessibilityValue("\(Int(value)) 밀리초")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: apply(value + 10)
            case .decrement: apply(value - 10)
            @unknown default: break
            }
        }
    }

    // MARK: Header (label, number scrubber, steppers)

    private var header: some View {
        HStack(spacing: 8) {
            Text("SYNC DELAY")
                .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                .foregroundStyle(Theme.text3)
            Spacer()
            roundButton("minus") { apply(value - (NSEvent.modifierFlags.contains(.shift) ? 10 : 1)) }
            numberField
            roundButton("plus") { apply(value + (NSEvent.modifierFlags.contains(.shift) ? 10 : 1)) }
            roundButton("arrow.counterclockwise") { apply(0) }
                .opacity(value == 0 ? 0.25 : 1)
                .help("0 ms로 리셋")
        }
    }

    private var numberField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(Int(value))")
                .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("ms").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2)
        }
        .frame(width: 88, height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hoverNumber || scrubStart != nil ? 0.14 : 0.07)))
        .onHover { inside in
            hoverNumber = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if scrubStart == nil { scrubStart = value }
                    let f = NSEvent.modifierFlags
                    let scale = f.contains(.shift) ? 10.0 : (f.contains(.option) ? 0.25 : 1.0)
                    apply((scrubStart ?? value) + Double(g.translation.width) * scale)
                }
                .onEnded { _ in scrubStart = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { apply(0) })
        .help("좌우로 드래그해서 조절 · ⇧ 10배 · ⌥ 정밀 · 더블클릭 리셋")
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text2)
    }

    // MARK: Ruler

    private let rulerHeight: CGFloat = 46

    private var ruler: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = CGFloat(value / maxValue) * w
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // Filled range.
                    let fill = CGRect(x: 0, y: size.height - 3, width: x, height: 3)
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: size.height - 3, width: size.width, height: 3), cornerRadius: 1.5),
                             with: .color(.white.opacity(0.08)))
                    ctx.fill(Path(roundedRect: fill, cornerRadius: 1.5), with: .linearGradient(
                        Gradient(colors: [Theme.violet, Theme.cyan]),
                        startPoint: .zero, endPoint: CGPoint(x: max(1, size.width), y: 0)))
                    // Ticks every 10 ms; taller every 50 and 100.
                    for ms in stride(from: 0, through: 1000, by: 10) {
                        let tx = CGFloat(ms) / 1000 * size.width
                        let major = ms % 100 == 0, mid = ms % 50 == 0
                        let h: CGFloat = major ? 14 : (mid ? 9 : 5)
                        let reached = Double(ms) <= value
                        var p = Path()
                        p.move(to: CGPoint(x: tx, y: size.height - 8))
                        p.addLine(to: CGPoint(x: tx, y: size.height - 8 - h))
                        ctx.stroke(p, with: .color(reached ? Theme.cyan.opacity(major ? 0.9 : 0.55) : .white.opacity(major ? 0.38 : 0.16)),
                                   lineWidth: 1)
                    }
                    // Labels every 100 ms (every 200 when narrow).
                    let step = size.width < 360 ? 200 : 100
                    for ms in stride(from: 0, through: 1000, by: step) {
                        let tx = CGFloat(ms) / 1000 * size.width
                        let t = Text(String(ms)).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.35))
                        let anchor: UnitPoint = ms == 0 ? .topLeading : (ms == 1000 ? .topTrailing : .top)
                        ctx.draw(t, at: CGPoint(x: tx, y: 0), anchor: anchor)
                    }
                }
                // Playhead.
                Capsule().fill(Theme.cyan)
                    .frame(width: 2, height: 30)
                    .shadow(color: Theme.cyan.opacity(0.7), radius: dragging ? 6 : 2)
                    .offset(x: x - 1, y: 12)
                Circle().fill(.white)
                    .frame(width: dragging ? 14 : 11, height: dragging ? 14 : 11)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(x: x - (dragging ? 7 : 5.5), y: rulerHeight - (dragging ? 17 : 14.5))
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
                // Floating value bubble while dragging.
                if dragging {
                    Text("\(Int(value)) ms")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accentDiagonal))
                        .foregroundStyle(.white)
                        .position(x: min(max(x, 30), w - 30), y: -10)
                        .transition(.opacity)
                }
            }
            .frame(width: w, height: rulerHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !draggingState { withAnimation(.easeOut(duration: 0.12)) { draggingState = true } }
                        let f = NSEvent.modifierFlags
                        // ⌥ = fine mode: the pointer moves the playhead at ¼ speed from where the drag began.
                        if f.contains(.option), let s = fineAnchor {
                            apply(s.value + Double(g.location.x - s.x) / Double(w) * maxValue * 0.25)
                        } else {
                            fineAnchor = (value, g.location.x)
                            apply(Double(g.location.x / w) * maxValue)
                        }
                    }
                    .onEnded { _ in
                        fineAnchor = nil
                        withAnimation(.easeOut(duration: 0.2)) { draggingState = false }
                    }
            )
        }
        .frame(height: rulerHeight)
        .padding(.top, 12)
    }

    @State private var fineAnchor: (value: Double, x: CGFloat)?

    // MARK: Apply with haptics

    private func apply(_ raw: Double) {
        let new = HapticPlanner.clamp(raw, limit: maxValue)
        guard new != value else { return }
        Haptics.play(HapticPlanner.event(from: value, to: new, limit: maxValue))
        onChange(new)
    }
}
