import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                header
                if let e = model.error { errorBanner(e) }
                HStack(alignment: .top, spacing: 18) {
                    inputsColumn.frame(width: 300)
                    outputsColumn
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
                footer
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 620)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentDiagonal)
                Symbol("waveform.path", size: 18, weight: .bold).foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .shadow(color: Theme.violet.opacity(0.5), radius: 10, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("AdvancedMIO").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("멀티 입출력 · 기기별 싱크 지연").font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            StatusPill(running: model.running)
            Button { model.refresh() } label: {
                Symbol("arrow.clockwise", size: 13)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain).help("장치 목록 새로고침")
            startButton
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)      // room for the hidden title bar's traffic lights
        .padding(.bottom, 16)
    }

    private var startButton: some View {
        Button { model.toggleRunning() } label: {
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small).tint(.white) }
                else { Symbol(model.running ? "stop.fill" : "play.fill", size: 12) }
                Text(model.running ? "정지" : "시작")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22).frame(height: 36)
            .background(Capsule().fill(model.running ? AnyShapeStyle(LinearGradient(colors: [Theme.pink, Color(hex: 0xFF8A5C)], startPoint: .leading, endPoint: .trailing))
                                                      : AnyShapeStyle(Theme.accent)))
            .shadow(color: (model.running ? Theme.pink : Theme.violet).opacity(0.5), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(model.busy)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Symbol("exclamationmark.triangle.fill", size: 14).foregroundStyle(Theme.pink)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9))
            Spacer()
            Button { model.error = nil } label: { Symbol("xmark", size: 10, weight: .bold) }
                .buttonStyle(.plain).foregroundStyle(Theme.text2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pink.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.pink.opacity(0.4)))
        .padding(.horizontal, 22).padding(.bottom, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Columns

    private func sectionTitle(_ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(Theme.text2)
            Spacer()
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 4)
    }

    private var inputsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("INPUTS", "\(model.selectedInputs.count)개 믹스")
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.inputDevices) { d in InputRow(device: d).environmentObject(model) }
                    if model.inputDevices.isEmpty { emptyState("입력 장치가 없습니다") }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var outputsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("OUTPUTS", "기기별 지연 0–1000 ms")
                Button { model.autoAlign() } label: {
                    Label("자동 맞춤", systemImage: "wand.and.stars").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.09)))
                }
                .buttonStyle(.plain)
                .disabled(!model.canAutoAlign)
                .opacity(model.canAutoAlign ? 1 : 0.35)
                .help("각 장치가 보고하는 하드웨어 지연을 기준으로, 가장 느린 장치에 맞춰 나머지를 늦춥니다 (블루투스는 실제와 다를 수 있음)")
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.outputDevices) { d in OutputCard(device: d).environmentObject(model) }
                    if model.outputDevices.isEmpty { emptyState("출력 장치가 없습니다") }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Symbol("info.circle", size: 12, weight: .regular).foregroundStyle(Theme.text3)
            Text("시스템 소리를 보내려면 ")
            + Text("BlackHole").foregroundColor(Theme.cyan)
            + Text(" 같은 가상 장치를 시스템 출력으로 지정하고, 여기서 그 장치를 입력으로 선택하세요.")
            Spacer()
            Link("BlackHole 받기", destination: URL(string: "https://existential.audio/blackhole/")!)
                .foregroundStyle(Theme.cyan)
        }
        .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
        .padding(.horizontal, 26).padding(.bottom, 14)
    }
}

// MARK: - Pieces

struct StatusPill: View {
    let running: Bool
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(running ? Color(hex: 0x3DDC97) : Color.white.opacity(0.3))
                .frame(width: 8, height: 8)
                .scaleEffect(running && pulse ? 1.35 : 1)
                .shadow(color: running ? Color(hex: 0x3DDC97).opacity(0.8) : .clear, radius: 4)
            Text(running ? "LIVE" : "대기 중").font(.system(size: 11, weight: .bold)).tracking(running ? 1.2 : 0)
        }
        .foregroundStyle(running ? Color(hex: 0x3DDC97) : Theme.text2)
        .padding(.horizontal, 12).frame(height: 28)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

struct InputRow: View {
    @EnvironmentObject var model: AppModel
    let device: AudioDeviceInfo

    var body: some View {
        let selected = model.selectedInputs.contains(device.uid)
        let blocked = model.isBlockedInput(device.uid)
        Button { model.toggleInput(device.uid) } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: device.symbol(forOutput: false), active: selected)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(device.transport.label) · \(device.inputChannels)ch")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    if selected && model.running { LevelMeter(source: { model.inputLevel(device.uid) }, height: 3) }
                }
                Spacer(minLength: 4)
                Symbol(selected ? "checkmark.circle.fill" : "circle", size: 18, weight: .regular)
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.22)))
            }
            .padding(12)
            .contentShape(Rectangle())
            .card(highlighted: selected)
        }
        .buttonStyle(.plain)
        .opacity(blocked ? 0.4 : 1)
        .disabled(blocked)
        .help(blocked ? "이 장치는 출력으로 사용 중이라 입력으로 쓸 수 없습니다 (하울링 방지)" : "")
    }
}

struct OutputCard: View {
    @EnvironmentObject var model: AppModel
    let device: AudioDeviceInfo

    var body: some View {
        let cfg = model.config(device.uid)
        let blocked = model.isBlockedOutput(device.uid)
        let on = cfg.enabled && !blocked
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
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { model.setEnabled(device.uid, $0) }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.violet)
                    .disabled(blocked)
                    .help(blocked ? "입력으로 선택된 장치는 출력으로 쓸 수 없습니다 (하울링 방지)" : "")
            }

            DelayScrubber(value: cfg.delayMs, onChange: { model.setDelay(device.uid, $0) }, enabled: on,
                          forceBubble: CommandLine.arguments.contains("--demo-drag") && device.uid == "AirPods Pro")

            HStack(spacing: 10) {
                Symbol(cfg.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 11, weight: .regular)
                    .foregroundStyle(Theme.text3).frame(width: 16)
                Slider(value: Binding(get: { cfg.volume }, set: { model.setVolume(device.uid, $0) }), in: 0...1)
                    .tint(Theme.violet).controlSize(.small)
                    .frame(width: 140)
                Text("\(Int((cfg.volume * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text3)
                    .frame(width: 34, alignment: .trailing)
                if on && model.running { LevelMeter(source: { model.outputLevel(device.uid) }, height: 4) }
                else { Capsule().fill(Color.white.opacity(0.06)).frame(height: 4) }
            }
            .opacity(on ? 1 : 0.4)
            .allowsHitTesting(on)
        }
        .padding(16)
        .card(highlighted: on)
    }
}
