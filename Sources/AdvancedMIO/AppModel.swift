import AppKit
import AVFoundation
import CoreAudio
import MIOCore
import SwiftUI

/// App state. This file holds the state and the routing core (devices, per-device settings, delays, engine lifecycle,
/// persistence); the rest lives in extensions:
/// `+Spatial`, `+Calibration`, `+Presets`, `+Latency`, `+Control` (menu bar, hotkeys, URL commands).
/// Properties are internal (not `private`) only because those extensions, in other files, work on them.
@MainActor
final class AppModel: ObservableObject {
    /// The one model: the window, the menu bar and URL / hotkey commands all drive it.
    static let shared = AppModel()

    /// Per-output volume is 0…100 (1 = unity). The system volume (AdvancedMIO device) tops out at unity.
    nonisolated static let maxVolume = 1.0
    nonisolated static let maxDelayMs = DelayReader.maxDelayMs
    /// UID of the virtual device the AdvancedMIO driver publishes (see driver/AdvancedMIODriver.c).
    nonisolated static let virtualUID = "AdvancedMIO_Device"
    static let driverInstallPath = "/Library/Audio/Plug-Ins/HAL/AdvancedMIO.driver"

    // MARK: State

    @Published private(set) var devices: [AudioDeviceInfo] = []
    @Published var outputs: [String: OutputConfig] = [:]
    /// The user switched routing on. The engine itself (and the macOS mic indicator) only runs while something plays.
    @Published private(set) var running = false
    /// The engine is actually capturing right now.
    @Published private(set) var capturing = false
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var hwLatencyMs: [String: Double] = [:]
    /// Nominal sample rate of each device, and of the virtual source: where they differ the router converts.
    @Published private(set) var deviceRates: [String: Double] = [:]
    @Published private(set) var installing = false
    /// The installed driver is too old to publish shared memory (and has no system volume control).
    @Published private(set) var driverOutdated = false
    @Published private(set) var hwVolume: [String: Double] = [:]

    // Spatial audio (see SpatialView): each enabled output is a point on a circle around the listener.
    @Published var spatialOn = false
    @Published var listenerHeadingDeg = 0.0

    // Presets (see AppModel+Presets).
    @Published var presets: [Preset] = []
    @Published var activePresetID: UUID?

    /// System-wide ⌃⌥⌘ shortcuts (see AppModel+Control).
    @Published var hotkeysEnabled = UserDefaults.standard.object(forKey: "hotkeys") as? Bool ?? true

    // Latency watch (see AppModel+Latency).
    @Published var latencyAlerts: [LatencyAlert] = []
    @Published var latencyWarningsEnabled = true
    var dismissedLatency: [String: Double] = [:]

    // Calibration (see AppModel+Calibration / CalibrationRunner / CalibrationView)
    enum CalPhase { case idle, setup, running, done, failed }
    @Published var calPhase: CalPhase = .idle
    @Published var calStatus = ""
    @Published var calFraction = 0.0
    @Published var calReport: CalibrationReport?
    @Published var calError: String?
    /// The one microphone the calibration listens with.
    @Published var calMics: Set<String> = []
    /// Seconds left according to the estimate (nil once it is overrun: "wrapping up").
    @Published var calRemaining: Double?
    /// Best measured improvement so far while the search runs (0…1).
    @Published var calBestSoFar: Double?
    /// The search has started, so "finish now with the best so far" makes sense.
    @Published var calCanFinishEarly = false
    @Published var calFinishRequested = false
    @Published var calListening: Bool?        // nil = not playing, false = original, true = calibrated
    @Published var calFeedbackGiven = false
    @Published var calCharts: CalibrationCharts?
    @Published var calHistory: [CalibrationRecord] = []
    @Published var calRoomName = UserDefaults.standard.string(forKey: "calibration.roomName") ?? "내 방"
    var calRecordID: UUID?
    var calTask: Task<Void, Never>?
    var calControl = CalibrationControl()
    var calStarted = Date()
    var testEngine: RouterEngine?
    var presetVolumes: [String: Double] = [:]
    var listenSong: LoopSource?

    // Engine lifecycle
    var engine: RouterEngine?
    private var pollTimer: Timer?
    private var hwTimer: Timer?
    private var hwTicks = 0
    private var idleSince: Date?
    private static let idleGrace: TimeInterval = 3
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    /// Audio from the driver's shared memory (no microphone indicator). nil → older driver, falls back to capturing the input.
    private var shared: SharedRingSource?
    var demo = false

    // MARK: Derived

    /// The virtual "AdvancedMIO" device: what the user picks in Control Center. Its loopback input is our only source.
    var virtualDevice: AudioDeviceInfo? { devices.first { $0.uid == Self.virtualUID && $0.isInput } }
    /// Real outputs only; the virtual device itself would feed back into the router.
    var outputDevices: [AudioDeviceInfo] { devices.filter { $0.isOutput && $0.uid != Self.virtualUID } }
    /// Enabled outputs in a stable order (the order the default slots are handed out in).
    var enabledOutputs: [AudioDeviceInfo] { outputDevices.filter { config($0.uid).enabled } }
    var micDevices: [AudioDeviceInfo] { devices.filter { $0.isInput && $0.uid != Self.virtualUID } }
    var sourceRate: Double? { deviceRates[Self.virtualUID] }

    // MARK: Init

    init() {
        DevStore.applySavedWeight()
        if CommandLine.arguments.contains("--demo") { loadDemo(); return }
        if let d = UserDefaults.standard.data(forKey: "state.v1"),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            outputs = s.outputs
            spatialOn = s.spatialOn ?? false
            listenerHeadingDeg = s.listenerHeadingDeg ?? 0
        }
        presets = Store.loadPresets()
        calHistory = Store.loadHistory()
        activePresetID = UserDefaults.standard.string(forKey: "presets.active").flatMap(UUID.init)
        latencyWarningsEnabled = UserDefaults.standard.object(forKey: "latencyWarnings") as? Bool ?? true
        refresh()
        installDeviceListener()
        hwTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.slowTick() }
        }
        if virtualDevice != nil, outputs.values.contains(where: \.enabled) { arm() }   // ready as soon as it's picked in Control Center
    }

    /// Once a second: follow volume changes made elsewhere (keys, Sound settings); every few seconds re-read latencies.
    private func slowTick() {
        refreshHardwareVolumes()
        hwTicks += 1
        if hwTicks % 5 == 0 { refreshLatencies() }
    }

    // MARK: Devices

    func refresh() {
        devices = HAL.allDevices()
        var lat: [String: Double] = [:], rates: [String: Double] = [:]
        for d in devices {
            if d.isOutput, let ms = HAL.outputLatencyMs(d.id) { lat[d.uid] = ms }
            if let r = HAL.nominalSampleRate(d.id) { rates[d.uid] = r }
        }
        hwLatencyMs = lat
        deviceRates = rates
        refreshHardwareVolumes()
        if shared == nil { shared = SharedRingSource.open() }
        driverOutdated = !demo && virtualDevice != nil && shared == nil
        pushDelays()
        updateLatencyAlerts()
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

    // MARK: Volume

    func refreshHardwareVolumes() {
        var next: [String: Double] = [:]
        // Virtual / aggregate devices report a volume control that does not change what is heard: those are always
        // adjusted in software (digital gain inside the router).
        for d in outputDevices where d.transport != .virtual && d.transport != .aggregate {
            if let v = HAL.hardwareVolume(d.id) { next[d.uid] = Double(v) }
        }
        if next.count != hwVolume.count || next.contains(where: { abs((hwVolume[$0.key] ?? -1) - $0.value) > 0.004 }) { hwVolume = next }
    }
    /// What the slider shows: the device's own volume if it has one, else the router's digital volume.
    func deviceVolume(_ uid: String) -> Double { hwVolume[uid] ?? config(uid).volume }
    /// The gain applied inside the router: unity for devices whose own volume is controlled directly.
    func digitalVolume(_ uid: String) -> Double { hwVolume[uid] != nil ? 1 : config(uid).volume }
    func usesHardwareVolume(_ uid: String) -> Bool { hwVolume[uid] != nil }

    func setDeviceVolume(_ uid: String, _ v: Double) {
        let v = min(1, max(0, v))
        if hwVolume[uid] != nil, let d = devices.first(where: { $0.uid == uid }), HAL.setHardwareVolume(d.id, Float(v)) {
            hwVolume[uid] = v
            var c = config(uid); c.volume = v; outputs[uid] = c     // remembered for presets
            scheduleSave()
        } else {
            setVolume(uid, v)
        }
    }

    func setVolume(_ uid: String, _ v: Double) {
        var c = config(uid); c.volume = min(Self.maxVolume, max(0, v)); outputs[uid] = c
        engine?.setGain(uid: uid, Float(digitalVolume(uid)))
        testEngine?.setGain(uid: uid, Float(digitalVolume(uid)))
        scheduleSave()
    }

    // MARK: Config

    func config(_ uid: String) -> OutputConfig { outputs[uid] ?? OutputConfig() }

    /// The lag this device is assumed to have: its reported hardware latency (auto) or the user's value (manual).
    /// This is what the slider shows; every other output is delayed to match the laggiest one.
    func totalLag(_ uid: String) -> Double {
        let c = config(uid)
        return HapticPlanner.clamp(c.auto ? (hwLatencyMs[uid] ?? 0) : c.manualLagMs, limit: Self.maxDelayMs)
    }

    /// Dragging the slider takes the device out of auto.
    func setTotalLag(_ uid: String, _ ms: Double) {
        var c = config(uid)
        if c.auto { c.hwBaselineMs = hwLatencyMs[uid] }
        c.auto = false
        c.manualLagMs = HapticPlanner.clamp(ms, limit: Self.maxDelayMs)
        commit(uid, c)
    }

    /// Turning auto off keeps the slider where it is, so the value can be nudged from there.
    func setAuto(_ uid: String, _ on: Bool) {
        var c = config(uid)
        if !on { c.manualLagMs = totalLag(uid); c.hwBaselineMs = hwLatencyMs[uid] }
        c.auto = on
        commit(uid, c)
    }

    func commit(_ uid: String, _ c: OutputConfig) {
        guard c != config(uid) || outputs[uid] == nil else { return }
        outputs[uid] = c
        pushDelays()
        scheduleSave()
    }

    func setEnabled(_ uid: String, _ on: Bool) {
        var c = config(uid); c.enabled = on; outputs[uid] = c
        scheduleSave()
        pushDelays()
        if running { rebuildEngine() }
    }

    func setEQ(_ uid: String, _ eq: EQSettings) {
        var c = config(uid); c.eq = eq; outputs[uid] = c
        engine?.setEQ(uid: uid, eq)
        scheduleSave()
    }

    /// Puts every device back on its reported hardware latency.
    func allAuto() {
        for uid in outputs.keys { outputs[uid]?.auto = true }
        pushDelays()
        scheduleSave()
        updateLatencyAlerts()
        Haptics.major()
    }

    var canAllAuto: Bool { outputs.values.contains { !$0.auto } }

    /// The lowest lag among the enabled devices is above 0, so every slider can move down by that much.
    var canZeroLag: Bool { (enabledOutputs.map { totalLag($0.uid) }.min() ?? 0) >= 0.5 }

    /// Moves all enabled devices' lags down together until the lowest is 0. The differences between devices — and so
    /// what is heard — stay exactly as they were; only the numbers shrink (and leave room below the 1000 ms limit).
    func zeroMinLag() {
        let list = enabledOutputs
        guard canZeroLag else { return }
        let shifted = LagMath.shiftedToZero(list.map { totalLag($0.uid) })
        for (d, lag) in zip(list, shifted) {
            var c = config(d.uid)
            c.auto = false
            c.manualLagMs = lag
            c.hwBaselineMs = hwLatencyMs[d.uid]
            outputs[d.uid] = c
        }
        pushDelays()
        scheduleSave()
        updateLatencyAlerts()
        Haptics.major()
    }

    /// Delay applied to an output so that it lands together with the laggiest enabled one (which gets 0).
    /// Calibration measures and solves on this alone (plain stereo, no placement).
    func syncDelayMs(_ uid: String) -> Double {
        let worst = enabledOutputs.map { totalLag($0.uid) }.max() ?? 0
        return HapticPlanner.clamp(worst - totalLag(uid), limit: Self.maxDelayMs)
    }

    /// What the router actually applies: the sync delay plus, with spatial audio on, the distance alignment.
    func appliedDelayMs(_ uid: String) -> Double {
        HapticPlanner.clamp(syncDelayMs(uid) + spatialDelayMs(uid), limit: Self.maxDelayMs)
    }

    /// The enabled output that everything else is waiting for.
    func isReference(_ uid: String) -> Bool {
        config(uid).enabled && syncDelayMs(uid) < 0.5 && enabledOutputs.count > 1
    }

    func pushDelays() {
        for e in [engine, testEngine] {
            guard let e else { continue }
            for d in enabledOutputs { e.setDelay(uid: d.uid, ms: appliedDelayMs(d.uid)) }
        }
        pushMixes()     // placements change whenever the set of enabled outputs does (default slots)
    }

    /// The calibration test engine is left alone: it must measure the plain signal.
    func pushEQs() {
        guard let engine else { return }
        for d in enabledOutputs { engine.setEQ(uid: d.uid, config(d.uid).eq) }
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

    func tick() {
        guard running, calPhase == .idle else { return }
        if shared == nil { shared = SharedRingSource.open() }
        // Shared memory: audio is flowing when the driver's write position moved. Otherwise ask the driver how many
        // clients play; an older driver without that counter means we simply always capture.
        let playing: Bool
        if let shared { playing = shared.pollActivity() }
        else { playing = virtualDevice.flatMap { HAL.playbackClients($0.id) }.map { $0 > 0 } ?? true }
        if playing {
            idleSince = nil
            if engine == nil { rebuildEngine() }
        } else if engine != nil {
            let since = idleSince ?? Date()
            idleSince = since
            if Date().timeIntervalSince(since) > Self.idleGrace { stopEngine() }
        }
    }

    func rebuildEngine() {
        guard !busy, running, calPhase == .idle else { return }
        busy = true
        Task {
            defer { busy = false }
            error = nil
            guard let virtual = virtualDevice else { error = "AdvancedMIO 가상 장치가 설치되어 있지 않습니다"; return }
            // Shared memory needs neither microphone permission nor an input stream (so no orange indicator).
            if shared == nil { guard await ensureMicAccess() else { disarm(); return } }
            stopEngine()
            let ins = shared == nil ? [virtual] : []
            let outs = enabledOutputs
            guard !outs.isEmpty else { error = "출력 장치를 하나 이상 켜세요"; return }
            do {
                let e = try RouterEngine(inputs: ins, shared: shared, outputs: outs.map { ($0, appliedDelayMs($0.uid), digitalVolume($0.uid)) })
                try e.start()
                engine = e
                pushMixes()
                pushEQs()
                if !e.failures.isEmpty {
                    error = e.failures.map { "\($0.name) 출력 실패: \($0.message)" }.joined(separator: "\n")
                }
                capturing = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func stopEngine() {
        engine?.stop(); engine = nil
        capturing = false
    }

    func ensureMicAccess() async -> Bool {
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
            "MacBook Pro 스피커": OutputConfig(enabled: true, volume: 0.9),
            "AirPods Pro": OutputConfig(enabled: true, volume: 0.7),
            "LG UltraFine": OutputConfig(enabled: true, auto: false, manualLagMs: 80, volume: 1),
            "Studio Display 스피커": OutputConfig(enabled: false, volume: 1),
        ]
        hwLatencyMs = ["MacBook Pro 스피커": 14, "AirPods Pro": 192, "LG UltraFine": 38, "Studio Display 스피커": 21,
                       AppModel.virtualUID: 5, "Scarlett 2i2 USB": 9]
        deviceRates = ["MacBook Pro 스피커": 48000, "AirPods Pro": 48000, "LG UltraFine": 44100, "Studio Display 스피커": 48000,
                       AppModel.virtualUID: 48000]
        running = true
        capturing = true
        spatialOn = true
        outputs["AirPods Pro"]?.angleDeg = 120
        outputs["AirPods Pro"]?.aimOffsetDeg = 35
        presets = [Preset(name: "거실", outputs: outputs, spatialOn: true, listenerHeadingDeg: 0),
                   Preset(name: "책상", outputs: outputs, spatialOn: false, listenerHeadingDeg: 0)]
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var outputs: [String: OutputConfig]
        var spatialOn: Bool?
        var listenerHeadingDeg: Double?
    }
    /// Written immediately: a debounce could drop the last change if the app quits right after.
    func scheduleSave() {
        guard !demo else { return }
        if let d = try? JSONEncoder().encode(Saved(outputs: outputs, spatialOn: spatialOn, listenerHeadingDeg: listenerHeadingDeg)) {
            UserDefaults.standard.set(d, forKey: "state.v1")
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
