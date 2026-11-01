import AppKit
import MIOCore
import SwiftUI

/// The SOURCE column's second tab: speakers placed on a circle around the listener.
struct SpatialCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let on = model.spatialOn
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: "person.wave.2.fill", active: on)
                VStack(alignment: .leading, spacing: 3) {
                    Text("공간음향").font(.system(size: 14, weight: .semibold))
                    Text(on ? "스피커 위치에 맞춰 소리를 나눠 재생" : "꺼짐 · 모든 기기가 같은 소리")
                        .font(.system(size: 11)).foregroundStyle(on ? Theme.cyan : Theme.text3)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { model.setSpatialOn($0) }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.violet)
            }

            if model.enabledOutputs.isEmpty {
                Text("오른쪽에서 소리를 낼 장치를 켜면 여기에 나타납니다")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity).padding(.vertical, 60)
            } else {
                SpatialStage()
                    .frame(height: SpatialStage.side)
                    .frame(maxWidth: .infinity)
                    .opacity(on ? 1 : 0.5)
                legend
                Text("각 기기는 점 하나로 취급되어 위치에 맞는 소리를 냅니다. 노드를 끌면 위치, 작은 점을 끌면 스피커 방향, 가운데 사람의 점을 끌면 정면이 바뀝니다 (⌥ = 5° 단위).")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                Button { model.resetSpatial() } label: {
                    HStack(spacing: 5) {
                        Symbol("arrow.counterclockwise", size: 11)
                        Text("배치 초기화")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.09)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .card(highlighted: on)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(model.enabledOutputs.enumerated()), id: \.element.id) { i, d in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.system(size: 10, weight: .bold, design: .rounded))
                        .frame(width: 16, height: 16).background(Circle().fill(Theme.violet.opacity(0.55)))
                    Text(d.name).font(.system(size: 11.5)).lineLimit(1)
                    Spacer()
                    Text("\(Int(model.spatialAngle(d.uid).rounded()))° · 방향 \(Int(model.spatialAimOffset(d.uid).rounded()))°")
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Theme.text3)
                }
            }
        }
    }
}

/// Circle with the listener in the middle. 0° is the top; angles grow clockwise.
struct SpatialStage: View {
    static let side: CGFloat = 236
    private let ring: CGFloat = SpatialStage.side / 2 - 22
    private let aimReach: CGFloat = 21

    @EnvironmentObject var model: AppModel

    private var centre: CGPoint { CGPoint(x: Self.side / 2, y: Self.side / 2) }

    private func point(_ deg: Double, _ r: CGFloat, from o: CGPoint) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: o.x + r * CGFloat(sin(a)), y: o.y - r * CGFloat(cos(a)))
    }
    private func angle(from o: CGPoint, to p: CGPoint) -> Double {
        atan2(Double(p.x - o.x), -Double(p.y - o.y)) * 180 / .pi
    }
    private func snapped(_ deg: Double) -> Double {
        NSEvent.modifierFlags.contains(.option) ? (deg / 5).rounded() * 5 : deg
    }
    /// Direction the speaker actually points in (stage angle).
    private func aim(_ uid: String) -> Double { model.spatialAngle(uid) + 180 + model.spatialAimOffset(uid) }

    var body: some View {
        let speakers = model.enabledOutputs
        let heading = model.listenerHeadingDeg
        ZStack {
            Canvas { ctx, _ in
                let c = centre
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)),
                           with: .color(.white.opacity(0.16)), lineWidth: 1)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ring / 2, y: c.y - ring / 2, width: ring, height: ring)),
                           with: .color(.white.opacity(0.07)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                for d in speakers {
                    let p = point(model.spatialAngle(d.uid), ring, from: c)
                    var line = Path(); line.move(to: c); line.addLine(to: p)
                    ctx.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 1)
                    // The cone the speaker projects its sound into.
                    let a = aim(d.uid)
                    var cone = Path(); cone.move(to: p)
                    for s in 0...8 { cone.addLine(to: point(a - 30 + 60 * Double(s) / 8, 46, from: p)) }
                    cone.closeSubpath()
                    ctx.fill(cone, with: .color(Theme.cyan.opacity(0.16)))
                }
                // The listener's line of sight.
                var look = Path(); look.move(to: c); look.addLine(to: point(heading, ring - 18, from: c))
                ctx.stroke(look, with: .color(Theme.pink.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }

            // Listener
            ZStack {
                Circle().fill(Color.white.opacity(0.1)).frame(width: 34, height: 34)
                Symbol("person.fill", size: 17).foregroundStyle(.white)
            }
            .position(centre)
            .allowsHitTesting(false)
            handle(color: Theme.pink)
                .position(point(heading, 27, from: centre))
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("stage")).onChanged { g in
                    model.setListenerHeading(snapped(angle(from: centre, to: g.location)))
                })
                .help("사람이 바라보는 방향")

            ForEach(Array(speakers.enumerated()), id: \.element.id) { i, d in
                let pos = point(model.spatialAngle(d.uid), ring, from: centre)
                ZStack {
                    Circle().fill(Theme.accentDiagonal).frame(width: 28, height: 28)
                        .shadow(color: Theme.violet.opacity(0.5), radius: 6)
                    Text("\(i + 1)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
                .position(pos)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("stage")).onChanged { g in
                    model.setSpatialAngle(d.uid, snapped(angle(from: centre, to: g.location)))
                })
                .help(d.name)

                handle(color: Theme.cyan)
                    .position(point(aim(d.uid), aimReach, from: pos))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("stage")).onChanged { g in
                        let facing = model.spatialAngle(d.uid) + 180
                        model.setSpatialAimOffset(d.uid, snapped(angle(from: pos, to: g.location) - facing))
                    })
                    .help("\(d.name)이(가) 바라보는 방향")
            }
        }
        .coordinateSpace(name: "stage")
        .frame(width: Self.side, height: Self.side)
    }

    private func handle(color: Color) -> some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
            .padding(8).contentShape(Circle())      // a finger-sized hit area around the small dot
    }
}
