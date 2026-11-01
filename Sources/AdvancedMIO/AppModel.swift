import AppKit
import CoreAudio
import SwiftUI

struct OutputConfig: Codable {
    var enabled = false
    var delayMs: Double = 0
    var volume: Double = 1
}

@MainActor
final class AppModel: ObservableObject {
    static let maxDelayMs: Double = 1000

    @Published var devices: [AudioDeviceInfo] = []
    @Published var selectedInputs: Set<String> = [] { didSet { save() } }
    @Published var outputs: [String: OutputConfig] = [:] { didSet { save() } }
    @Published var running = false
    @Published var error: String?

    private var captures: [String: InputCapture] = [:]
    private var renderers: [String: OutputRenderer] = [:]

    var inputDevices: [AudioDeviceInfo] { devices.filter { $0.inputChannels > 0 } }
    var outputDevices: [AudioDeviceInfo] { devices.filter { $0.outputChannels > 0 } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "state"),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            selectedInputs = s.inputs; outputs = s.outputs
        }
        refresh()
    }

    func refresh() { devices = AudioDevices.all() }

    func config(_ uid: String) -> OutputConfig { outputs[uid] ?? OutputConfig() }

    func setDelay(_ uid: String, _ ms: Double) {
        var c = config(uid); c.delayMs = min(Self.maxDelayMs, max(0, ms.rounded()))
        outputs[uid] = c
        renderers[uid]?.setDelay(ms: c.delayMs)
    }
    func setEnabled(_ uid: String, _ on: Bool) {
        var c = config(uid); c.enabled = on; outputs[uid] = c
        if running { restart() }
    }
    func setVolume(_ uid: String, _ v: Double) {
        var c = config(uid); c.volume = v; outputs[uid] = c
        renderers[uid]?.setGain(Float(v))
    }
    func toggleInput(_ uid: String, _ on: Bool) {
        if on { selectedInputs.insert(uid) } else { selectedInputs.remove(uid) }
        if running { restart() }
    }

    func start() {
        stop()
        error = nil
        let ins = inputDevices.filter { selectedInputs.contains($0.uid) }
        let outs = outputDevices.filter { config($0.uid).enabled }
        guard !ins.isEmpty, !outs.isEmpty else { error = "입력과 출력을 각각 하나 이상 선택하세요"; return }
        do {
            for d in ins { captures[d.uid] = try InputCapture(deviceID: d.id) }
            let caps = ins.compactMap { captures[$0.uid] }
            for d in outs {
                // Skip routing an output back into its own input device (feedback).
                let c = config(d.uid)
                let r = try OutputRenderer(deviceID: d.id, inputs: caps, delayMs: c.delayMs)
                r.setGain(Float(c.volume))
                renderers[d.uid] = r
            }
            running = true
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func stop() {
        renderers.values.forEach { $0.stop() }; renderers = [:]
        captures.values.forEach { $0.stop() }; captures = [:]
        running = false
    }

    private func restart() { start() }

    private struct Saved: Codable { var inputs: Set<String>; var outputs: [String: OutputConfig] }
    private func save() {
        if let d = try? JSONEncoder().encode(Saved(inputs: selectedInputs, outputs: outputs)) {
            UserDefaults.standard.set(d, forKey: "state")
        }
    }
}

enum Haptics {
    static func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func major() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    static func edge() { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
}
