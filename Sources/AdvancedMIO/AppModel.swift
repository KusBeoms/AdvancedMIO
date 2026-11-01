import AppKit
import AVFoundation
import CoreAudio
import MIOCore
import SwiftUI

struct OutputConfig: Codable, Equatable {
    var enabled = false
    var delayMs: Double = 0
    var volume: Double = 1
}

@MainActor
final class AppModel: ObservableObject {
    nonisolated static let maxDelayMs = DelayReader.maxDelayMs

    @Published private(set) var devices: [AudioDeviceInfo] = []
    @Published private(set) var selectedInputs: Set<String> = []
    @Published private(set) var outputs: [String: OutputConfig] = [:]
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var hwLatencyMs: [String: Double] = [:]

    private var engine: RouterEngine?
    private var saveTask: Task<Void, Never>?
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    var inputDevices: [AudioDeviceInfo] { devices.filter(\.isInput) }
    var outputDevices: [AudioDeviceInfo] { devices.filter(\.isOutput) }

    init() {
        if let d = UserDefaults.standard.data(forKey: "state.v1"),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            selectedInputs = s.inputs
            outputs = s.outputs
        }
        refresh()
        installDeviceListener()
    }

    // MARK: Devices

    func refresh() {
        devices = HAL.allDevices()
        var lat: [String: Double] = [:]
        for d in devices where d.isOutput { if let ms = HAL.outputLatencyMs(d.id) { lat[d.uid] = ms } }
        hwLatencyMs = lat
    }

    private func installDeviceListener() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.devicesChanged() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func devicesChanged() {
        refresh()
        guard running else { return }
        let present = Set(devices.map(\.uid))
        let used = selectedInputs.union(outputs.filter { $0.value.enabled }.keys)
        if !used.isSubset(of: present) {
            stopEngine()
            error = "사용 중이던 오디오 장치가 분리되어 정지했습니다"
        }
    }

    // MARK: Config

    func config(_ uid: String) -> OutputConfig { outputs[uid] ?? OutputConfig() }

    func setDelay(_ uid: String, _ ms: Double) {
        var c = config(uid)
        c.delayMs = HapticPlanner.clamp(ms, limit: Self.maxDelayMs)
        guard c != config(uid) || outputs[uid] == nil else { return }
        outputs[uid] = c
        engine?.setDelay(uid: uid, ms: c.delayMs)
        scheduleSave()
    }

    func setVolume(_ uid: String, _ v: Double) {
        var c = config(uid); c.volume = min(1, max(0, v)); outputs[uid] = c
        engine?.setGain(uid: uid, Float(c.volume))
        scheduleSave()
    }

    func setEnabled(_ uid: String, _ on: Bool) {
        var c = config(uid); c.enabled = on; outputs[uid] = c
        scheduleSave()
        if running { start() }
    }

    func toggleInput(_ uid: String) {
        if selectedInputs.contains(uid) { selectedInputs.remove(uid) } else { selectedInputs.insert(uid) }
        scheduleSave()
        if running { start() }
    }

    /// An output can't also be an active input (it would feed back into itself).
    func isBlockedOutput(_ uid: String) -> Bool { selectedInputs.contains(uid) }
    func isBlockedInput(_ uid: String) -> Bool { outputs[uid]?.enabled == true && !selectedInputs.contains(uid) }

    /// Offsets every enabled output so they all land at the same time as the slowest one (based on reported HW latency).
    func autoAlign() {
        let active = outputDevices.filter { config($0.uid).enabled }
        let lat = active.compactMap { d in hwLatencyMs[d.uid].map { (d.uid, $0) } }
        guard let slowest = lat.map(\.1).max() else { return }
        for (uid, ms) in lat { setDelay(uid, slowest - ms) }
        Haptics.major()
    }

    var canAutoAlign: Bool { outputDevices.filter { config($0.uid).enabled && hwLatencyMs[$0.uid] != nil }.count >= 2 }

    // MARK: Run

    func toggleRunning() { running ? stopEngine() : start() }

    func start() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            error = nil
            guard await ensureMicAccess() else { return }
            stopEngine()
            let ins = inputDevices.filter { selectedInputs.contains($0.uid) }
            let outs = outputDevices.filter { config($0.uid).enabled && !selectedInputs.contains($0.uid) }
            guard !ins.isEmpty else { error = "입력 장치를 하나 이상 선택하세요"; return }
            guard !outs.isEmpty else { error = "출력 장치를 하나 이상 켜세요"; return }
            do {
                let e = try RouterEngine(inputs: ins, outputs: outs.map { ($0, config($0.uid)) })
                try e.start()
                engine = e
                running = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func stopEngine() {
        engine?.stop(); engine = nil
        running = false
    }

    private func ensureMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return true }
            fallthrough
        default:
            error = "마이크 권한이 필요합니다 — 시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 마이크에서 AdvancedMIO를 허용하세요"
            return false
        }
    }

    func inputLevel(_ uid: String) -> Float { engine?.inputLevel(uid: uid) ?? 0 }
    func outputLevel(_ uid: String) -> Float { engine?.outputLevel(uid: uid) ?? 0 }

    // MARK: Persistence

    private struct Saved: Codable { var inputs: Set<String>; var outputs: [String: OutputConfig] }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [selectedInputs, outputs] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            if let d = try? JSONEncoder().encode(Saved(inputs: selectedInputs, outputs: outputs)) {
                UserDefaults.standard.set(d, forKey: "state.v1")
            }
        }
    }
}

enum Haptics {
    static func play(_ e: HapticEvent) {
        let p = NSHapticFeedbackManager.defaultPerformer
        switch e {
        case .none: break
        case .tick: p.perform(.alignment, performanceTime: .now)
        case .major: p.perform(.levelChange, performanceTime: .now)
        case .edge: p.perform(.generic, performanceTime: .now)
        }
    }
    static func major() { play(.major) }
}
