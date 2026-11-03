import SwiftUI

/// Past room calibrations: how much each one improved the sound, and whether the last one still fits.
struct CalibrationHistorySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        ZStack {
            Backdrop()
            VStack(alignment: .leading, spacing: 14) {
                Text("캘리브레이션 기록").font(.system(size: 20, weight: .bold, design: .rounded))
                if let why = model.calibrationStaleReason {
                    HStack(alignment: .top, spacing: 10) {
                        Symbol("arrow.triangle.2.circlepath", size: 13).foregroundStyle(Color(hex: 0xFFB84D))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("재측정을 권장합니다").font(.system(size: 12.5, weight: .semibold))
                            Text(why).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0xFFB84D).opacity(0.13)))
                }
                if model.calHistory.isEmpty {
                    Text("아직 기록이 없습니다. 룸 캘리브레이션을 마치면 여기에 쌓입니다.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text2).padding(.vertical, 30).frame(maxWidth: .infinity)
                } else {
                    if model.calHistory.contains(where: { $0.unit == "ms" }) { trend }
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(model.calHistory.reversed()) { row($0) }
                        }
                    }
                }
                HStack { Spacer(); Button("닫기") { dismiss() }.buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 18).frame(height: 34)
                    .background(Capsule().fill(Color.white.opacity(0.1))) }
            }
            .padding(26)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(width: 560, height: 600)
    }

    /// Arrival-time spread of every measurement: original (grey) and calibrated (cyan), oldest to newest.
    private var trend: some View {
        let rows = model.calHistory.filter { $0.unit == "ms" }.suffix(12)
        let top = max(1, rows.flatMap { [$0.measuredBefore ?? 0, $0.measuredAfter ?? 0] }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("스피커 간 도착 시간 차이 추이 (ms, 낮을수록 좋음)").font(.system(size: 12.5, weight: .semibold))
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(rows)) { r in
                    HStack(alignment: .bottom, spacing: 2) {
                        column(r.measuredBefore, top: top, color: Color.white.opacity(0.4))
                        column(r.measuredAfter, top: top, color: Theme.cyan)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 56)
        }
        .padding(14).card()
    }

    private func column(_ v: Double?, top: Double, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(color).frame(height: max(2, 56 * CGFloat((v ?? 0) / top)))
    }

    private func row(_ r: CalibrationRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.roomName).font(.system(size: 13.5, weight: .semibold))
                    Text(Self.dateFormat.string(from: r.date) + (r.applied ? " · 적용함" : " · 적용 안 함"))
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                if let imp = r.improvement, let b = r.measuredBefore, let a = r.measuredAfter {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(imp < 0.02 ? "개선 없음" : "−\(Int((imp * 100).rounded()))%")
                            .font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(imp < 0.02 ? Theme.text2 : Theme.cyan)
                        Text(String(format: "%.1f → %.1f", b, a) + (r.unit == "ms" ? " ms" : "")).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.text3)
                    }
                }
                Button { model.deleteCalibrationRecord(r.id) } label: { Symbol("trash", size: 11, weight: .regular) }
                    .buttonStyle(.plain).foregroundStyle(Theme.text3).help("기록 삭제")
            }
            ForEach(Array(r.speakerNames.enumerated()), id: \.offset) { i, name in
                if i < r.calibratedDelaysMs.count, i < r.originalDelaysMs.count {
                    HStack {
                        Text(name).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                        Spacer()
                        Text(String(format: "+%.1f → +%.1f ms", r.originalDelaysMs[i], r.calibratedDelaysMs[i]))
                            .font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundStyle(Theme.text2)
                    }
                }
            }
        }
        .padding(14).card()
    }
}
