import AppKit
import SwiftUI

/// The menu bar menu: routing on/off, presets, device switches, window, settings.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(statusText) {}.disabled(true)
        Button(model.running ? "정지" : "시작") { model.toggleRunning() }
            .keyboardShortcut("s", modifiers: [.control, .option, .command])

        Divider()
        if model.presets.isEmpty {
            Button("프리셋 없음 — 창에서 저장하세요") {}.disabled(true)
        } else {
            Menu("프리셋") {
                ForEach(Array(model.presets.enumerated()), id: \.element.id) { i, p in
                    Toggle(p.name, isOn: Binding(get: { model.activePresetID == p.id }, set: { _ in model.applyPreset(p.id) }))
                        .keyboardShortcut(i < 9 ? KeyEquivalent(Character("\(i + 1)")) : "0", modifiers: [.control, .option, .command])
                }
            }
        }
        Menu("출력 장치") {
            ForEach(model.outputDevices) { d in
                Toggle(d.name, isOn: Binding(get: { model.config(d.uid).enabled }, set: { model.setEnabled(d.uid, $0) }))
            }
        }
        Button("가장 낮은 지연을 0으로") { model.zeroMinLag() }
            .keyboardShortcut("z", modifiers: [.control, .option, .command])
            .disabled(!model.canZeroLag)

        Divider()
        Button("창 열기") { openWindow(id: "main"); AppWindow.show() }
        Menu("설정") {
            Toggle("지연 변화 경고 표시", isOn: Binding(get: { model.latencyWarningsEnabled }, set: { model.setLatencyWarnings($0) }))
            Toggle("전역 단축키 (⌃⌥⌘)", isOn: Binding(get: { model.hotkeysEnabled }, set: { model.setHotkeys($0) }))
            Toggle("로그인 시 자동 실행", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        }
        Divider()
        Button("AdvancedMIO 종료") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var statusText: String {
        if model.capturing { return "● 재생 중 · \(model.enabledOutputs.count)개 출력" }
        return model.running ? "재생 대기" : "정지됨"
    }
}
