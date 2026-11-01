import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                inputs.frame(width: 260)
                Divider()
                outputs
            }
        }
        .frame(minWidth: 860, minHeight: 440)
    }

    private var header: some View {
        HStack {
            Text("AdvancedMIO").font(.title2.bold())
            Spacer()
            if let e = model.error { Text(e).foregroundStyle(.red).font(.callout) }
            Button("새로고침") { model.refresh() }
            Button(model.running ? "정지" : "시작") { model.running ? model.stop() : model.start() }
                .buttonStyle(.borderedProminent)
                .tint(model.running ? .red : .accentColor)
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("입력 (여러 개 믹스)").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.inputDevices) { d in
                        Toggle(d.name, isOn: Binding(
                            get: { model.selectedInputs.contains(d.uid) },
                            set: { model.toggleInput(d.uid, $0) }))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("시스템 소리를 보내려면 BlackHole 같은 가상 장치를 시스템 출력으로 지정하고 여기서 입력으로 선택하세요.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14)
    }

    private var outputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("출력 (기기별 지연 0–1000 ms)").font(.headline)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.outputDevices) { d in row(d) }
                }
            }
        }.padding(14)
    }

    private func row(_ d: AudioDeviceInfo) -> some View {
        let cfg = model.config(d.uid)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(d.name, isOn: Binding(get: { cfg.enabled }, set: { model.setEnabled(d.uid, $0) }))
                Spacer()
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: Binding(get: { cfg.volume }, set: { model.setVolume(d.uid, $0) }), in: 0...1)
                    .frame(width: 90)
            }
            DelayScrubber(value: Binding(get: { cfg.delayMs }, set: { model.setDelay(d.uid, $0) }))
                .opacity(cfg.enabled ? 1 : 0.45)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}
