import MIOCore
import SwiftUI

/// Result plots: when each speaker's sound reaches the microphone, and how uneven the sound is across frequency —
/// with the original delays (grey) and the calibrated ones (cyan).
struct CalibrationChartsView: View {
    let charts: CalibrationCharts

    private let before = Color.white.opacity(0.4), after = Theme.cyan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            arrivals
            deviation
        }
    }

    // MARK: Arrival times

    private var arrivals: some View {
        let limit = max(1, (charts.before.arrivalsMs + charts.after.arrivalsMs).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            header("도착 시간 (마이크에 닿는 시각 차이)", "짧을수록 소리가 동시에 도착")
            ForEach(Array(charts.names.enumerated()), id: \.offset) { i, name in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(name).font(.system(size: 11.5)).lineLimit(1)
                        Spacer()
                        Text("\(ms(charts.before.arrivalsMs[i])) → \(ms(charts.after.arrivalsMs[i])) ms")
                            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(Theme.text2)
                    }
                    bar(charts.before.arrivalsMs[i] / limit, color: before)
                    bar(charts.after.arrivalsMs[i] / limit, color: after)
                }
            }
            legend
        }
    }

    private func bar(_ fraction: Double, color: Color) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.05))
                Capsule().fill(color).frame(width: max(3, g.size.width * min(1, fraction)))
            }
        }
        .frame(height: 4)
    }

    // MARK: Spectrum

    private var deviation: some View {
        let all = charts.before.deviationDb + charts.after.deviationDb
        let span = max(6, ceil((all.map { abs($0) }.max() ?? 6) / 3) * 3)
        return VStack(alignment: .leading, spacing: 8) {
            header("음색 편차 (1/6 옥타브, 100 Hz–8 kHz)", "평평할수록 고른 소리 · ±\(Int(span)) dB 범위")
            Canvas { ctx, size in
                let w = size.width, h = size.height
                func x(_ hz: Double) -> CGFloat {
                    CGFloat((log2(hz) - log2(100)) / (log2(8000) - log2(100))) * w
                }
                func y(_ db: Double) -> CGFloat { h / 2 - CGFloat(max(-span, min(span, db)) / span) * (h / 2 - 2) }
                for hz in [100.0, 1000, 8000] {
                    var g = Path(); g.move(to: CGPoint(x: x(hz), y: 0)); g.addLine(to: CGPoint(x: x(hz), y: h))
                    ctx.stroke(g, with: .color(.white.opacity(0.06)), lineWidth: 1)
                }
                var zero = Path(); zero.move(to: CGPoint(x: 0, y: h / 2)); zero.addLine(to: CGPoint(x: w, y: h / 2))
                ctx.stroke(zero, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                for (view, color, width) in [(charts.before, before, 1.5), (charts.after, after, 2.0)] {
                    var p = Path()
                    for (k, hz) in view.centersHz.enumerated() {
                        let pt = CGPoint(x: x(hz), y: y(view.deviationDb[k]))
                        if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 86)
            HStack {
                Text("100 Hz"); Spacer(); Text("1 kHz"); Spacer(); Text("8 kHz")
            }
            .font(.system(size: 9.5)).foregroundStyle(Theme.text3)
            legend
        }
    }

    // MARK: Bits

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(sub).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) { Circle().fill(before).frame(width: 6, height: 6); Text("원래") }
            HStack(spacing: 5) { Circle().fill(after).frame(width: 6, height: 6); Text("계산된") }
        }
        .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
    }

    private func ms(_ v: Double) -> String { String(format: "%.1f", v) }
}
