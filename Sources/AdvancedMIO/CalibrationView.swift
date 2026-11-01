import SwiftUI

/// Room calibration window: balance volumes by ear with the test song → measure with microphones → apply the delays.
struct CalibrationSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Backdrop()
            VStack(alignment: .leading, spacing: 16) {
                switch model.calPhase {
                case .setup: setup
                case .running: running
                case .done: done
                case .failed: failed
                case .idle: EmptyView()
                }
            }
            .padding(26)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(width: 560, height: 640)
    }

    // MARK: Steps

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("1 · 음량 맞추기", "테스트 노래가 켜진 스피커로 흘러나옵니다. 방 곳곳에서 들으며 소리가 고르게 퍼지도록 음량을 정하세요. 측정은 이 음량 그대로 하고, 음량은 바꾸지 않습니다.")
            HStack(spacing: 8) {
                chip("현재 프리셋", selected: !model.calVolumesChanged) { model.calUsePreset() }
                chip("새로 설정 (50%)", selected: false) { model.calStartFresh() }
                Spacer()
            }
            VStack(spacing: 10) {
                ForEach(model.calSpeakers) { d in
                    let cfg = model.config(d.uid)
                    HStack(spacing: 10) {
                        Symbol(d.symbol(forOutput: true), size: 13).foregroundStyle(Theme.cyan).frame(width: 20)
                        Text(d.name).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(width: 150, alignment: .leading)
                        Slider(value: Binding(get: { model.deviceVolume(d.uid) }, set: { model.setDeviceVolume(d.uid, $0) }), in: 0...AppModel.maxVolume)
                            .tint(Theme.cyan)
                        Text("\(Int((model.deviceVolume(d.uid) * 100).rounded()))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            .padding(14).card()

            Text("측정에 사용할 마이크").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.micDevices) { m in
                    Toggle(isOn: Binding(get: { model.calMics.contains(m.uid) },
                                         set: { on in if on { model.calMics.insert(m.uid) } else { model.calMics.remove(m.uid) } })) {
                        Text("\(m.name)  ·  \(m.transport.label)").font(.system(size: 12.5))
                    }
                    .toggleStyle(.checkbox)
                }
                Text("마이크를 여러 개 고르면 차례로 한 번씩 측정해 모든 위치에서 울림이 적은 설정을 찾습니다. 측정할 때마다 마이크를 청취 위치에 두세요.")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            if let e = model.calError { Text(e).font(.system(size: 12)).foregroundStyle(Theme.pink) }
            Spacer(minLength: 0)
            HStack {
                button("취소", primary: false) { model.closeCalibration() }
                Spacer()
                button("측정 시작 · 약 \(Int(model.calEstimate.rounded()))초", primary: true) { model.startMeasurement() }
                    .disabled(model.calMics.isEmpty)
                    .opacity(model.calMics.isEmpty ? 0.4 : 1)
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("2 · 측정 중", "노래가 끊기지 않고 이어집니다. 먼저 한 기기씩 음량을 부드럽게 바꿔 스피커 위치를 파악하고, 이어서 기기별 지연을 과감하게 바꿔 가며 실제로 울림이 가장 적은 값을 찾습니다. 끝날 때까지 조용히 해 주세요. ")
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: model.calFraction).tint(Theme.cyan)
                Text(model.calStatus).font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            .padding(18).card()
            Spacer()
            HStack { Spacer(); button("중단", primary: false) { model.closeCalibration() } }
        }
    }

    private var done: some View {
        let r = model.calReport
        return VStack(alignment: .leading, spacing: 14) {
            title("3 · 결과", "모든 스피커를 함께 틀어 실제로 측정해 가며 찾은, 울림이 가장 적은 설정입니다. 적용하면 기기별 지연이 이 값으로 바뀝니다 (음량은 그대로).")
            if let r {
                let o = r.outcome
                VStack(alignment: .leading, spacing: 10) {
                    if let mb = r.measuredBefore, let ma = r.measuredAfter, let imp = r.measuredImprovement {
                        Text(imp < 0.02 ? "측정 결과 개선이 확인되지 않았습니다" : "울림 지수 \(fmt(mb)) → \(fmt(ma))  (−\(Int((imp * 100).rounded()))%)")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    } else {
                        Text("원래 설정을 측정하지 못해 비교할 수 없습니다").font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    Text("마이크 \(r.micsUsed.joined(separator: ", ")) 평균 · 낮을수록 울림이 적음 · \(r.evaluations)가지 설정을 실제로 시험")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    Divider().overlay(Color.white.opacity(0.1))
                    ForEach(Array(r.speakerNames.enumerated()), id: \.offset) { i, name in
                        HStack {
                            Text(name).font(.system(size: 13)).lineLimit(1)
                            Spacer()
                            if r.excluded.contains(name) {
                                Text("제외 (소리 안 잡힘)").font(.system(size: 12)).foregroundStyle(Theme.text3)
                            } else {
                                Text("지연 +\(fmt(o.delaysMs[i])) ms").font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(Theme.cyan)
                            }
                        }
                    }
                }
                .padding(16).card(highlighted: true)
                VStack(alignment: .leading, spacing: 4) {
                    if r.searchHistory.count > 1 {
                        Text("탐색 경과 (±200 → ±5 ms 단계별 최고값): " + r.searchHistory.map { fmt($0) }.joined(separator: " → "))
                            .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    if !r.reliable {
                        Text("⚠︎ 개선 폭이 5% 미만이라 신뢰하기 어려운 결과입니다 (측정 오차 범위).")
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.pink)
                    }
                    if !r.finished {
                        Text("시간 제한으로 가장 세밀한 단계까지는 시험하지 못했습니다.").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                    if let f = r.fit {
                        Text("수식 모델 적합도 \(Int((f * 100).rounded()))% (시작점 계산용 참고값)").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }
                ForEach(r.warnings, id: \.self) { Text("⚠︎ \($0)").font(.system(size: 11.5)).foregroundStyle(Theme.pink).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            HStack {
                button("닫기", primary: false) { model.closeCalibration() }
                Spacer()
                button("다시 측정", primary: false) { model.backToCalibrationSetup() }
                button("이 설정 적용", primary: true) { model.applyCalibration() }
                    .disabled((r?.measuredImprovement ?? 1) < 0.02)
                    .opacity((r?.measuredImprovement ?? 1) < 0.02 ? 0.4 : 1)
            }
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("측정 실패", "")
            HStack(alignment: .top, spacing: 12) {
                Symbol("exclamationmark.triangle.fill", size: 18).foregroundStyle(Theme.pink)
                Text(model.calError ?? "알 수 없는 오류").font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).card()
            Spacer()
            HStack {
                button("닫기", primary: false) { model.closeCalibration() }
                Spacer()
                button("다시 시도", primary: true) { model.backToCalibrationSetup() }
            }
        }
    }

    // MARK: Bits

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    private func title(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(.system(size: 20, weight: .bold, design: .rounded))
            if !sub.isEmpty {
                Text(sub).font(.system(size: 12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(selected ? AnyShapeStyle(Theme.accent.opacity(0.9)) : AnyShapeStyle(Color.white.opacity(0.09))))
        }
        .buttonStyle(.plain)
    }

    private func button(_ text: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 18).frame(height: 34)
                .background(Capsule().fill(primary ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.1))))
        }
        .buttonStyle(.plain)
    }
}
