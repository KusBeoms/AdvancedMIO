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
    @Published private(set) var outputs: [String: OutputConfig] = [:]
    /// The user switched routing on. The engine itself (and the macOS mic indicator) only runs while something plays.
    @Published private(set) var running = false
    /// The engine is actually capturing right now.
    @Published private(set) var capturing = false
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var hwLatencyMs: [String: Double] = [:]

    private var engine: RouterEngine?
    private var pollTimer: Timer?
    private var idleSince: Date?
    private static let idleGrace: TimeInterval = 3
    private var saveTask: Task<Void, Never>?
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// UID of the virtual device the AdvancedMIO driver publishes (see driver/AdvancedMIODriver.c).
    nonisolated static let virtualUID = "AdvancedMIO_Device"
    static let driverInstallPath = "/Library/Audio/Plug-Ins/HAL/AdvancedMIO.driver"

    /// The virtual "AdvancedMIO" device: what the user picks in Control Center. Its loopback input is our only source.
    var virtualDevice: AudioDeviceInfo? { devices.first { $0.uid == Self.virtualUID && $0.isInput } }
    /// Real outputs only; the virtual device itself would feed back into the router.
    var outputDevices: [AudioDeviceInfo] { devices.filter { $0.isOutput && $0.uid != Self.virtualUID } }
    @Published private(set) var installing = false

    private var demo = false

    init() {
        if CommandLine.arguments.contains("--demo") { loadDemo(); return }
        if let d = UserDefaults.standard.data(forKey: "state.v1"),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            outputs = s.outputs
        }
        refresh()
        installDeviceListener()
        if virtualDevice != nil, outputs.values.contains(where: \.enabled) { arm() }   // ready as soon as it's picked in Control Center
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
        let used = Set(outputs.filter { $0.value.enabled }.keys).union([Self.virtualUID])
        if !used.isSubset(of: present) {
            disarm()
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
        if running { rebuildEngine() }
    }

    // MARK: Driver install

    /// Copies the bundled driver into /Library/Audio/Plug-Ins/HAL (admin password prompt) and restarts coreaudiod.
    func installDriver() {
        guard !installing else { return }
        guard let src = Bundle.main.url(forResource: "AdvancedMIO.driver", withExtension: nil)?.path else {
            error = "앱 안에 드라이버가 없습니다 — scripts/bundle.sh 로 만든 앱인지 확인하세요"
            return
        }
        installing = true
        error = nil
        let dest = Self.driverInstallPath
        let cmd = "rm -rf '\(dest)' && cp -R '\(src)' '\(dest)' && chown -R root:wheel '\(dest)' && (killall coreaudiod || true)"
        Task.detached {
            let script = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
            var info: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&info)
            let failure = (info?[NSAppleScript.errorMessage] as? String)
            // coreaudiod needs a moment to come back and publish the device.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                self.installing = false
                if let failure { self.error = "드라이버 설치 실패: \(failure)" }
                self.refresh()
                if self.virtualDevice == nil, failure == nil {
                    self.error = "설치는 끝났지만 장치가 아직 보이지 않습니다. 몇 초 뒤 새로고침하거나 Mac을 재시작하세요"
                }
            }
        }
    }

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

    func toggleRunning() { running ? disarm() : arm() }

    /// Turn routing on: the engine starts as soon as something plays to the AdvancedMIO device.
    func arm() {
        running = true
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func disarm() {
        pollTimer?.invalidate(); pollTimer = nil
        running = false
        stopEngine()
    }

    private func tick() {
        guard running else { return }
        // An older driver without the playback counter: always capture.
        let clients = virtualDevice.flatMap { HAL.playbackClients($0.id) }
        let playing = clients.map { $0 > 0 } ?? true
        if playing {
            idleSince = nil
            if engine == nil { rebuildEngine() }
        } else if engine != nil {
            let since = idleSince ?? Date()
            idleSince = since
            if Date().timeIntervalSince(since) > Self.idleGrace { stopEngine() }
        }
    }

    private func rebuildEngine() {
        guard !busy, running else { return }
        busy = true
        Task {
            defer { busy = false }
            error = nil
            guard await ensureMicAccess() else { disarm(); return }
            stopEngine()
            guard let virtual = virtualDevice else { error = "AdvancedMIO 가상 장치가 설치되어 있지 않습니다"; return }
            let ins = [virtual]
            let outs = outputDevices.filter { config($0.uid).enabled }
            guard !outs.isEmpty else { error = "출력 장치를 하나 이상 켜세요"; return }
            do {
                let e = try RouterEngine(inputs: ins, outputs: outs.map { ($0, config($0.uid)) })
                try e.start()
                engine = e
                capturing = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func stopEngine() {
        engine?.stop(); engine = nil
        capturing = false
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

    func inputLevel(_ uid: String) -> Float {
        demo ? demoLevel(uid) : (engine?.inputLevel(uid: uid) ?? 0)
    }
    func outputLevel(_ uid: String) -> Float {
        demo ? demoLevel(uid) : (engine?.outputLevel(uid: uid) ?? 0)
    }

    // MARK: Demo (used for screenshots: `AdvancedMIO --demo`)

    private func demoLevel(_ uid: String) -> Float {
        let t = Date.timeIntervalSinceReferenceDate
        let seed = Double(abs(uid.hashValue % 97))
        return Float(0.12 + 0.3 * abs(sin(t * 3 + seed)) * abs(sin(t * 1.3 + seed * 0.5)))
    }

    private func loadDemo() {
        demo = true
        func dev(_ id: UInt32, _ name: String, _ i: Int, _ o: Int, _ t: DeviceTransport) -> AudioDeviceInfo {
            AudioDeviceInfo(id: id, uid: name, name: name, inputChannels: i, outputChannels: o, transport: t)
        }
        devices = [
            dev(4, "MacBook Pro 스피커", 0, 2, .builtIn),
            dev(5, "AirPods Pro", 0, 2, .bluetooth),
            dev(6, "LG UltraFine", 0, 2, .hdmi),
            dev(7, "Studio Display 스피커", 0, 2, .usb),
            dev(1, AppModel.virtualUID, 2, 2, .virtual),
            dev(2, "MacBook Pro 마이크", 1, 0, .builtIn),
            dev(3, "Scarlett 2i2 USB", 2, 2, .usb),
        ]
        outputs = [
            "MacBook Pro 스피커": OutputConfig(enabled: true, delayMs: 0, volume: 0.9),
            "AirPods Pro": OutputConfig(enabled: true, delayMs: 180, volume: 0.7),
            "LG UltraFine": OutputConfig(enabled: true, delayMs: 520, volume: 1),
            "Studio Display 스피커": OutputConfig(enabled: false, delayMs: 0, volume: 1),
        ]
        hwLatencyMs = ["MacBook Pro 스피커": 14, "AirPods Pro": 192, "LG UltraFine": 38, "Studio Display 스피커": 21,
                       AppModel.virtualUID: 5, "Scarlett 2i2 USB": 9]
        running = true
        capturing = true
    }

    // MARK: Persistence

    private struct Saved: Codable { var outputs: [String: OutputConfig] }
    private func scheduleSave() {
        guard !demo else { return }
        saveTask?.cancel()
        saveTask = Task { [outputs] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            if let d = try? JSONEncoder().encode(Saved(outputs: outputs)) {
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
