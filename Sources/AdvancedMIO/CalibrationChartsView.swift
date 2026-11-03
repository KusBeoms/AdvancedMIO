import MIOCore
import SwiftUI

/// Result plot: when each speaker's sound reaches the microphone, with the original delays (grey) and the calibrated ones (cyan).
/// The shorter the bars (and the more alike), the more simultaneously the sounds arrive.
struct CalibrationChartsView: View {
    let charts: CalibrationCharts

    private let before = Color.white.opacity(0.4), after = Theme.cyan

    var body: some View {
        let limit = max(1, (charts.beforeMs + charts.afterMs).max() ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("도착 시간 (가장 먼저 닿는 스피커 기준)").font(.system(size: 12.5, weight: .semibold))
                Text("막대가 모두 짧을수록 소리가 동시에 도착").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            ForEach(Array(charts.names.enumerated()), id: \.offset) { i, name in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(name).font(.system(size: 11.5)).lineLimit(1)
                        Spacer()
                        Text("\(ms(charts.beforeMs[i])) → \(ms(charts.afterMs[i])) ms")
                            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(Theme.text2)
                    }
                    bar(charts.beforeMs[i] / limit, color: before)
                    bar(charts.afterMs[i] / limit, color: after)
                }
            }
            HStack(spacing: 12) {
                HStack(spacing: 5) { Circle().fill(before).frame(width: 6, height: 6); Text("원래") }
                HStack(spacing: 5) { Circle().fill(after).frame(width: 6, height: 6); Text("계산된") }
            }
            .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
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

    private func ms(_ v: Double) -> String { String(format: "%.1f", v) }
}
