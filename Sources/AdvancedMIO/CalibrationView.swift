import MIOCore
import SwiftUI

/// Speaker-timing calibration window: balance volumes by ear with the test song → record the song once with a microphone → apply the delays that line the arrivals up.
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
        .frame(width: 600, height: 740)
    }

    // MARK: Steps

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("1 · 음량 맞추기", "테스트 노래가 켜진 스피커로 흘러나옵니다. 방 곳곳에서 들으며 소리가 고르게 퍼지도록 음량을 정하세요. 측정은 이 음량을 기준으로 하고, 측정이 끝나도 음량은 바뀌지 않습니다.")
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

            Text("측정에 사용할 마이크 (1개)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.micDevices) { m in
                    Button { model.selectCalMic(m.uid) } label: {
                        HStack(spacing: 8) {
                            Symbol(model.calMics.contains(m.uid) ? "largecircle.fill.circle" : "circle", size: 13)
                                .foregroundStyle(model.calMics.contains(m.uid) ? Theme.cyan : Theme.text3)
                            Text("\(m.name)  ·  \(m.transport.label)").font(.system(size: 12.5))
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text("마이크를 가장 잘 듣고 싶은 청취 위치에 두세요. 마이크 하나로 충분히 정확하게 맞춰집니다.")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            Text("측정 방식").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
            HStack(spacing: 8) {
                chip("노래 전체 · 약 \(Int(CalibrationRunner.estimatedSeconds(speakers: model.calSpeakers.count, mics: 1, wholeSong: true).rounded()))초", selected: model.calWholeSong) { model.calWholeSong = true }
                chip("빠르게 · 약 \(Int(CalibrationRunner.estimatedSeconds(speakers: model.calSpeakers.count, mics: 1, wholeSong: false).rounded()))초", selected: !model.calWholeSong) { model.calWholeSong = false }
            }
            Text(model.calWholeSong ? "노래를 처음부터 끝까지 한 번 틀며 녹음합니다. 구간이 많아 잡음이 있어도 가장 정확합니다."
                                    : "음량 패턴 한 바퀴만 녹음합니다. 조용한 방에서 빠르게 확인할 때 쓰세요.")
                .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            if let e = model.calError { Text(e).font(.system(size: 12)).foregroundStyle(Theme.pink) }
            Spacer(minLength: 0)
            HStack {
                button("취소", primary: false) { model.closeCalibration() }
                Spacer()
                button("측정 시작", primary: true) { model.startMeasurement() }
                    .disabled(model.calMics.isEmpty)
                    .opacity(model.calMics.isEmpty ? 0.4 : 1)
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("2 · 측정 중", model.calWholeSong ? "노래를 처음부터 끝까지 한 번 틀면서 녹음합니다. 그동안 기기를 하나씩 번갈아 음량을 부드럽게 키우고 줄여서 어느 소리가 어느 스피커인지 구별합니다 (음량이 조금씩 오르내리는 게 정상입니다). 노래가 끝나면 녹음 전체로 스피커별 도착 시간을 한 번에 계산합니다. 끝날 때까지 조용히 해 주세요." : "기기를 하나씩 번갈아 음량을 부드럽게 키우고 줄이며 녹음합니다 (음량이 오르내리는 게 정상입니다). 끝나면 스피커별 도착 시간을 계산합니다. 끝날 때까지 조용히 해 주세요.")
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: model.calFraction).tint(Theme.cyan)
                Text(model.calStatus).font(.system(size: 13)).foregroundStyle(Theme.text2)
                HStack(spacing: 14) {
                    Text(model.calRemaining.map { "남은 시간 약 \(Int($0.rounded()))초" } ?? "마무리 중…")
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                }
            }
            .padding(18).card()
            Spacer()
            HStack {
                button("중단", primary: false) { model.closeCalibration() }
                Spacer()
            }
        }
    }

    private var done: some View {
        let r = model.calReport
        return VStack(alignment: .leading, spacing: 14) {
            title("3 · 결과", "스피커마다 소리가 마이크에 닿는 시간을 재서, 모두 같은 순간 닿도록 계산한 지연입니다. 적용하면 기기별 지연이 이 값으로 바뀝니다 (음량은 그대로).")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let r { resultBody(r) }
                }
                .padding(.trailing, 6)
            }
            HStack {
                button("닫기", primary: false) { model.closeCalibration() }
                Spacer()
                button("다시 측정", primary: false) { model.backToCalibrationSetup() }
                button("이 설정 적용", primary: true) { model.applyCalibration() }
                    .disabled(r?.alreadyAligned ?? false)
                    .opacity((r?.alreadyAligned ?? false) ? 0.4 : 1)
            }
        }
    }

    @ViewBuilder private func resultBody(_ r: CalibrationReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(r.alreadyAligned ? "이미 소리가 거의 같은 순간에 도착합니다 (도착 시간 차이 \(fmt(r.spreadBeforeMs)) ms)"
                                  : "스피커 간 도착 시간 차이 \(fmt(r.spreadBeforeMs)) ms → \(fmt(r.spreadAfterMs)) ms")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text("마이크 \(r.micsUsed.joined(separator: ", ")) 위치 기준")
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
            HStack(spacing: 8) {
                Text("방 이름").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                TextField("내 방", text: Binding(get: { model.calRoomName }, set: { model.setCalRoomName($0) }))
                    .textFieldStyle(.plain).font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            Divider().overlay(Color.white.opacity(0.1))
            ForEach(Array(r.speakerNames.enumerated()), id: \.offset) { i, name in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text("지연 +\(fmt(r.delaysMs[i])) ms").font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Theme.cyan)
                    }
                    HStack(spacing: 8) {
                        Text("원래 +\(fmt(r.originalDelaysMs[i])) ms · 이 기기는 마이크에 +\(fmt(r.arrivalsMs[i])) ms 늦게 닿음")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                        Spacer()
                        if r.inverted[i] { badge("극성 반전?", color: Theme.pink) }
                        badge(r.snr[i] >= CalibrationAnalysis.minReliableSNR ? "신호 양호" : "신호 약함",
                              color: r.snr[i] >= CalibrationAnalysis.minReliableSNR ? Theme.text3 : Theme.pink)
                    }
                }
            }
        }
        .padding(16).card(highlighted: true)

        if let c = model.calCharts {
            CalibrationChartsView(charts: c).padding(16).card()
        }

        VStack(alignment: .leading, spacing: 4) {
            ForEach(r.confidenceNotes, id: \.self) {
                Text("· \($0)").font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let bal = r.balance { balanceView(bal, names: r.speakerNames) }
        listenView(r)
        ForEach(r.warnings, id: \.self) { Text("⚠︎ \($0)").font(.system(size: 11.5)).foregroundStyle(Theme.pink).fixedSize(horizontal: false, vertical: true) }
    }

    /// Reference only: the user's volumes are not touched.
    private func balanceView(_ b: VolumeBalance.Suggestion, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("음량 균형 (참고용 · 자동으로 바꾸지 않습니다)").font(.system(size: 12.5, weight: .semibold))
            if b.spreadBeforeDb < 1.5 {
                Text("마이크 위치별 소리 크기 차이가 \(fmt(b.spreadBeforeDb)) dB로 이미 고릅니다.").font(.system(size: 11)).foregroundStyle(Theme.text2)
            } else {
                Text("마이크 위치별 소리 크기 차이 \(fmt(b.spreadBeforeDb)) dB → 아래처럼 조정하면 약 \(fmt(b.spreadAfterDb)) dB")
                    .font(.system(size: 11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                    if i < b.gainsDb.count, abs(b.gainsDb[i]) >= 0.5 {
                        Text("\(n)  \(b.gainsDb[i] > 0 ? "+" : "−")\(fmt(abs(b.gainsDb[i]))) dB")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(Theme.cyan)
                    }
                }
            }
        }
    }

    /// Listen to the same song with the original and the calibrated delays; the verdict is recorded next to the measured index.
    private func listenView(_ r: CalibrationReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("귀로 비교").font(.system(size: 12.5, weight: .semibold))
            HStack(spacing: 8) {
                chip("원래 설정 듣기", selected: model.calListening == false) { model.calListen(calibrated: false) }
                chip("계산된 설정 듣기", selected: model.calListening == true) { model.calListen(calibrated: true) }
                if model.calListening != nil { chip("정지", selected: false) { model.stopListening() } }
            }
            if model.calFeedbackGiven {
                Text("기록했습니다.").font(.system(size: 11)).foregroundStyle(Theme.text3)
            } else {
                HStack(spacing: 8) {
                    Text("어느 쪽이 더 좋았나요?").font(.system(size: 11)).foregroundStyle(Theme.text2)
                    chip("원래", selected: false) { model.recordFeedback(better: "original") }
                    chip("계산된", selected: false) { model.recordFeedback(better: "calibrated") }
                    chip("차이 없음", selected: false) { model.recordFeedback(better: "same") }
                }
            }
            let a = model.feedbackAgreement
            if a.total >= 3 {
                Text("지금까지 \(a.total)번 중 \(a.agree)번 측정 결과와 귀의 판단이 일치했습니다.").font(.system(size: 11)).foregroundStyle(Theme.text3)
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

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).frame(height: 18)
            .background(Capsule().fill(color.opacity(0.15)))
    }

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
