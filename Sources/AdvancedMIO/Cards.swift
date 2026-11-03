import MIOCore
import SwiftUI

// MARK: - Pieces

struct StatusPill: View {
    let running: Bool
    var armed = false
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(running ? Color(hex: 0x3DDC97) : Color.white.opacity(0.3))
                .frame(width: 8, height: 8)
                .scaleEffect(running && pulse ? 1.35 : 1)
                .shadow(color: running ? Color(hex: 0x3DDC97).opacity(0.8) : .clear, radius: 4)
            Text(running ? "LIVE" : (armed ? "재생 대기" : "대기 중")).font(.system(size: 11, weight: .bold)).tracking(running ? 1.2 : 0)
        }
        .foregroundStyle(running ? Color(hex: 0x3DDC97) : Theme.text2)
        .padding(.horizontal, 12).frame(height: 28)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

struct SourceCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let device = model.virtualDevice
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: "waveform.path", active: device != nil)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AdvancedMIO").font(.system(size: 14, weight: .semibold))
                    Text(device == nil ? "가상 출력 장치 · 설치 필요" : "가상 출력 장치 · 2ch 48 kHz")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Spacer()
            }
            if device != nil {
                if model.capturing { LevelMeter(source: { model.inputLevel(AppModel.virtualUID) }, height: 4) }
                else { Capsule().fill(Color.white.opacity(0.06)).frame(height: 4) }
                VStack(alignment: .leading, spacing: 6) {
                    step("1", "제어 센터 ▸ 소리 에서 AdvancedMIO 선택")
                    step("2", "오른쪽에서 소리를 내보낼 장치를 켜고 지연 조절")
                    if model.driverOutdated {
                        Text("설치된 드라이버가 오래되어 시스템 음량 조절이 안 되고 마이크 표시가 뜹니다. 업데이트하세요.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.pink).fixedSize(horizontal: false, vertical: true)
                        Button { model.installDriver() } label: {
                            HStack(spacing: 8) {
                                if model.installing { ProgressView().controlSize(.small).tint(.white) }
                                else { Symbol("arrow.triangle.2.circlepath", size: 12) }
                                Text(model.installing ? "업데이트 중…" : "드라이버 업데이트")
                            }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 32)
                            .background(Capsule().fill(Theme.accent))
                        }
                        .buttonStyle(.plain).disabled(model.installing)
                    }
                }
            } else {
                Text("제어 센터에 나타나는 출력 장치 'AdvancedMIO'를 만들려면 가상 오디오 드라이버를 한 번 설치해야 합니다. 관리자 암호를 물어봅니다.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                Button { model.installDriver() } label: {
                    HStack(spacing: 8) {
                        if model.installing { ProgressView().controlSize(.small).tint(.white) }
                        else { Symbol("square.and.arrow.down", size: 12) }
                        Text(model.installing ? "설치 중…" : "드라이버 설치")
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain).disabled(model.installing)
            }
        }
        .padding(16)
        .card(highlighted: device != nil)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(n).font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 16, height: 16).background(Circle().fill(Color.white.opacity(0.1)))
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
        }
    }
}

struct OutputCard: View {
    @EnvironmentObject var model: AppModel
    let device: AudioDeviceInfo
    @State private var eqOpen = false

    private static func khz(_ hz: Double) -> String { String(format: "%g kHz", (hz / 100).rounded() / 10) }

    /// The device's own sample rate; flagged when the router has to convert (the source runs at another rate).
    @ViewBuilder private var rateLabel: some View {
        if let r = model.deviceRates[device.uid] {
            Text("·")
            if let src = model.sourceRate, abs(src - r) > 1 {
                Text("\(Self.khz(r)) · \(Self.khz(src))에서 변환").foregroundStyle(Color(hex: 0xFFB84D))
            } else {
                Text(Self.khz(r))
            }
        }
    }

    @ViewBuilder private var appliedLabel: some View {
        if model.isReference(device.uid) {
            Text("기준 · 가장 늦은 기기").foregroundStyle(Theme.cyan)
                .font(.system(size: 11, weight: .medium))
        } else {
            let ms = model.appliedDelayMs(device.uid)
            Text(ms < 0.5 ? "지연 없음" : "기준에 맞춰 \(Int(ms.rounded())) ms 늦춤")
                .font(.system(size: 11)).foregroundStyle(Theme.text2)
        }
    }

    var body: some View {
        let cfg = model.config(device.uid)
        let on = cfg.enabled
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: device.symbol(forOutput: true), active: on)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(device.transport.label) · \(device.outputChannels)ch")
                        if let ms = model.hwLatencyMs[device.uid] {
                            Text("·"); Text("HW ≈ \(String(format: "%.0f", ms)) ms")
                        }
                        rateLabel
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    if on { appliedLabel }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { model.setEnabled(device.uid, $0) }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.violet)
            }

            DelayScrubber(value: model.totalLag(device.uid), onChange: { model.setTotalLag(device.uid, $0) }, enabled: on,
                          autoOn: cfg.auto, onAuto: { model.setAuto(device.uid, $0) },
                          forceBubble: CommandLine.arguments.contains("--demo-drag") && device.uid == "AirPods Pro")

            HStack(spacing: 10) {
                Symbol(model.deviceVolume(device.uid) == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 11, weight: .regular)
                    .foregroundStyle(Theme.text3).frame(width: 16)
                Slider(value: Binding(get: { model.deviceVolume(device.uid) }, set: { model.setDeviceVolume(device.uid, $0) }), in: 0...AppModel.maxVolume)
                    .tint(Theme.violet).controlSize(.small)
                    .frame(width: 140)
                Text("\(Int((model.deviceVolume(device.uid) * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text3)
                    .frame(width: 40, alignment: .trailing)
                if on && model.capturing { LevelMeter(source: { model.outputLevel(device.uid) }, height: 4) }
                else { Capsule().fill(Color.white.opacity(0.06)).frame(height: 4) }
            }
            .opacity(on ? 1 : 0.4)
            .allowsHitTesting(on)

            eqSection.opacity(on ? 1 : 0.4).allowsHitTesting(on)
        }
        .padding(16)
        .card(highlighted: on)
    }

    // MARK: EQ (low shelf 150 Hz · mid 1 kHz · high shelf 6 kHz)

    private var eqSection: some View {
        let eq = model.config(device.uid).eq
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { eqOpen.toggle() } } label: {
                    HStack(spacing: 6) {
                        Symbol(eqOpen ? "chevron.down" : "chevron.right", size: 9, weight: .bold)
                        Text("EQ").font(.system(size: 11, weight: .bold)).tracking(1)
                        if !eq.isFlat { Circle().fill(Theme.cyan).frame(width: 6, height: 6) }
                    }
                    .foregroundStyle(Theme.text2)
                }
                .buttonStyle(.plain)
                Spacer()
                if eqOpen && !eq.isFlat {
                    Button("초기화") { model.setEQ(device.uid, .flat) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                }
            }
            if eqOpen {
                HStack(spacing: 16) {
                    eqBand("저음", eq.lowDb) { model.setEQ(device.uid, EQSettings(lowDb: $0, midDb: eq.midDb, highDb: eq.highDb)) }
                    eqBand("중음", eq.midDb) { model.setEQ(device.uid, EQSettings(lowDb: eq.lowDb, midDb: $0, highDb: eq.highDb)) }
                    eqBand("고음", eq.highDb) { model.setEQ(device.uid, EQSettings(lowDb: eq.lowDb, midDb: eq.midDb, highDb: $0)) }
                }
            }
        }
    }

    private func eqBand(_ title: String, _ db: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 3) {
            // Snaps to 0 and to half-dB steps so "flat" is easy to hit.
            Slider(value: Binding(get: { db }, set: { set(abs($0) < 0.4 ? 0 : ($0 * 2).rounded() / 2) }),
                   in: -EQSettings.maxGainDb...EQSettings.maxGainDb)
                .tint(Theme.cyan).controlSize(.small)
            Text("\(title) \(db > 0 ? "+" : "")\(String(format: "%.1f", db)) dB")
                .font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text3)
        }
    }
}
