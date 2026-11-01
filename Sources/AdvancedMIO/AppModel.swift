import AppKit
import AVFoundation
import CoreAudio
import MIOCore
import SwiftUI

struct OutputConfig: Codable, Equatable {
    var enabled = false
    /// On: this device's lag is the hardware-reported latency. Off: `manualLagMs` is used instead.
    var auto = true
    var manualLagMs: Double = 0
    var volume: Double = 1
    /// Spatial audio: place on the circle (nil = the default slot for this device) and how far the speaker is
    /// turned away from facing the listener.
    var angleDeg: Double?
    var aimOffsetDeg: Double = 0

    init(enabled: Bool = false, auto: Bool = true, manualLagMs: Double = 0, volume: Double = 1,
         angleDeg: Double? = nil, aimOffsetDeg: Double = 0) {
        self.enabled = enabled; self.auto = auto; self.manualLagMs = manualLagMs; self.volume = volume
        self.angleDeg = angleDeg; self.aimOffsetDeg = aimOffsetDeg
    }

    // Tolerant of older saves (which stored a differently-meaning `delayMs`/`lagMs`; those are dropped).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? true
        manualLagMs = try c.decodeIfPresent(Double.self, forKey: .manualLagMs) ?? 0
        volume = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1))   // old saves went up to 200 %
        angleDeg = try c.decodeIfPresent(Double.self, forKey: .angleDeg)
        aimOffsetDeg = try c.decodeIfPresent(Double.self, forKey: .aimOffsetDeg) ?? 0
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// Per-output volume is 0…100 (1 = unity). The system volume (AdvancedMIO device) tops out at unity.
    nonisolated static let maxVolume = 1.0
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
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// UID of the virtual device the AdvancedMIO driver publishes (see driver/AdvancedMIODriver.c).
    nonisolated static let virtualUID = "AdvancedMIO_Device"
    static let driverInstallPath = "/Library/Audio/Plug-Ins/HAL/AdvancedMIO.driver"

    /// The virtual "AdvancedMIO" device: what the user picks in Control Center. Its loopback input is our only source.
    var virtualDevice: AudioDeviceInfo? { devices.first { $0.uid == Self.virtualUID && $0.isInput } }
    /// Real outputs only; the virtual device itself would feed back into the router.
    var outputDevices: [AudioDeviceInfo] { devices.filter { $0.isOutput && $0.uid != Self.virtualUID } }
    @Published private(set) var installing = false
    /// Audio from the driver's shared memory (no microphone indicator). nil → older driver, falls back to capturing the input.
    private var shared: SharedRingSource?
    /// The installed driver is too old to publish shared memory (and has no system volume control).
    @Published private(set) var driverOutdated = false

    private var demo = false

    // Spatial audio (see SpatialView): each enabled output is a point on a circle around the listener.
    @Published private(set) var spatialOn = false
    @Published private(set) var listenerHeadingDeg = 0.0

    /// Enabled outputs in a stable order (the order the default slots are handed out in).
    var enabledOutputs: [AudioDeviceInfo] { outputDevices.filter { config($0.uid).enabled } }

    /// Where this speaker stands on the circle: the user's placement, else its default slot.
    func spatialAngle(_ uid: String) -> Double {
        if let a = config(uid).angleDeg { return a }
        let list = enabledOutputs
        guard let i = list.firstIndex(where: { $0.uid == uid }) else { return 0 }
        return SpatialPanner.defaultAngles(count: list.count)[i]
    }
    func spatialAimOffset(_ uid: String) -> Double { config(uid).aimOffsetDeg }

    func setSpatialOn(_ on: Bool) {
        spatialOn = on
        pushMixes()
        scheduleSave()
    }
    func setListenerHeading(_ deg: Double) {
        listenerHeadingDeg = SpatialPanner.normalized(deg)
        pushMixes()
        scheduleSave()
    }
    func setSpatialAngle(_ uid: String, _ deg: Double) {
        var c = config(uid); c.angleDeg = SpatialPanner.normalized(deg)
        commit(uid, c)
    }
    func setSpatialAimOffset(_ uid: String, _ deg: Double) {
        var c = config(uid); c.aimOffsetDeg = SpatialPanner.normalized(deg)
        commit(uid, c)
    }
    func resetSpatial() {
        for uid in outputs.keys { outputs[uid]?.angleDeg = nil; outputs[uid]?.aimOffsetDeg = 0 }
        listenerHeadingDeg = 0
        pushMixes()
        scheduleSave()
    }

    /// Sends every speaker its placement mix (identity when spatial audio is off). The calibration test engine is
    /// left alone: it must measure the plain stereo signal.
    private func pushMixes() {
        guard let engine else { return }
        for d in enabledOutputs {
            let m = spatialOn
                ? SpatialPanner.mix(positionDeg: spatialAngle(d.uid), aimOffsetDeg: spatialAimOffset(d.uid), headingDeg: listenerHeadingDeg)
                : SpatialMix.identity
            engine.setMix(uid: d.uid, m)
        }
    }

    // Calibration (see CalibrationRunner / CalibrationView)
    enum CalPhase { case idle, setup, running, done, failed }
    @Published private(set) var calPhase: CalPhase = .idle
    @Published private(set) var calStatus = ""
    @Published private(set) var calFraction = 0.0
    @Published private(set) var calReport: CalibrationReport?
    @Published private(set) var calError: String?
    /// The one microphone the calibration listens with.
    @Published private(set) var calMics: Set<String> = []
    func selectCalMic(_ uid: String) { calMics = [uid] }
    private var calTask: Task<Void, Never>?
    private var calControl = CalibrationControl()
    private var calStarted = Date()
    /// Seconds left according to the estimate (nil once it is overrun: "wrapping up").
    @Published private(set) var calRemaining: Double?
    /// Best measured improvement so far while the search runs (0…1).
    @Published private(set) var calBestSoFar: Double?
    /// The search has started, so "finish now with the best so far" makes sense.
    @Published private(set) var calCanFinishEarly = false
    @Published private(set) var calFinishRequested = false
    private var testEngine: RouterEngine?
    private var presetVolumes: [String: Double] = [:]

    // Per-device volume: the real device's own hardware volume when it has one; virtual devices and devices
    // without one use a digital gain inside the router.
    @Published private(set) var hwVolume: [String: Double] = [:]
    private var hwTimer: Timer?

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
        } else {
            setVolume(uid, v)
        }
    }

    init() {
        if CommandLine.arguments.contains("--demo") { loadDemo(); return }
        if let d = UserDefaults.standard.data(forKey: "state.v1"),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            outputs = s.outputs
            spatialOn = s.spatialOn ?? false
            listenerHeadingDeg = s.listenerHeadingDeg ?? 0
        }
        refresh()
        installDeviceListener()
        hwTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHardwareVolumes() }     // follows changes made elsewhere (keys, Sound settings)
        }
        if virtualDevice != nil, outputs.values.contains(where: \.enabled) { arm() }   // ready as soon as it's picked in Control Center
    }

    // MARK: Devices

    func refresh() {
        devices = HAL.allDevices()
        var lat: [String: Double] = [:]
        for d in devices where d.isOutput { if let ms = HAL.outputLatencyMs(d.id) { lat[d.uid] = ms } }
        hwLatencyMs = lat
        refreshHardwareVolumes()
        if shared == nil { shared = SharedRingSource.open() }
        driverOutdated = !demo && virtualDevice != nil && shared == nil
        pushDelays()
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

    /// The lag this device is assumed to have: its reported hardware latency (auto) or the user's value (manual).
    /// This is what the slider shows; every other output is delayed to match the laggiest one.
    func totalLag(_ uid: String) -> Double {
        let c = config(uid)
        return HapticPlanner.clamp(c.auto ? (hwLatencyMs[uid] ?? 0) : c.manualLagMs, limit: Self.maxDelayMs)
    }

    /// Dragging the slider takes the device out of auto.
    func setTotalLag(_ uid: String, _ ms: Double) {
        var c = config(uid)
        c.auto = false
        c.manualLagMs = HapticPlanner.clamp(ms, limit: Self.maxDelayMs)
        commit(uid, c)
    }

    /// Turning auto off keeps the slider where it is, so the value can be nudged from there.
    func setAuto(_ uid: String, _ on: Bool) {
        var c = config(uid)
        if !on { c.manualLagMs = totalLag(uid) }
        c.auto = on
        commit(uid, c)
    }

    private func commit(_ uid: String, _ c: OutputConfig) {
        guard c != config(uid) || outputs[uid] == nil else { return }
        outputs[uid] = c
        pushDelays()
        scheduleSave()
    }

    /// Delay applied to an output so that it lands together with the laggiest enabled one (which gets 0).
    func appliedDelayMs(_ uid: String) -> Double {
        let worst = outputDevices.filter { config($0.uid).enabled }.map { totalLag($0.uid) }.max() ?? 0
        return HapticPlanner.clamp(worst - totalLag(uid), limit: Self.maxDelayMs)
    }

    /// The enabled output that everything else is waiting for.
    func isReference(_ uid: String) -> Bool {
        config(uid).enabled && appliedDelayMs(uid) < 0.5
            && outputDevices.filter { config($0.uid).enabled }.count > 1
    }

    private func pushDelays() {
        for e in [engine, testEngine] {
            guard let e else { continue }
            for d in outputDevices where config(d.uid).enabled { e.setDelay(uid: d.uid, ms: appliedDelayMs(d.uid)) }
        }
        pushMixes()     // placements change whenever the set of enabled outputs does (default slots)
    }

    func setVolume(_ uid: String, _ v: Double) {
        var c = config(uid); c.volume = min(Self.maxVolume, max(0, v)); outputs[uid] = c
        engine?.setGain(uid: uid, Float(digitalVolume(uid)))
        testEngine?.setGain(uid: uid, Float(digitalVolume(uid)))
        scheduleSave()
    }

    func setEnabled(_ uid: String, _ on: Bool) {
        var c = config(uid); c.enabled = on; outputs[uid] = c
        scheduleSave()
        pushDelays()
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

    /// Puts every device back on its reported hardware latency.
    func allAuto() {
        for uid in outputs.keys { outputs[uid]?.auto = true }
        pushDelays()
        scheduleSave()
        Haptics.major()
    }

    var canAllAuto: Bool { outputs.values.contains { !$0.auto } }

    // MARK: Calibration

    var micDevices: [AudioDeviceInfo] { devices.filter { $0.isInput && $0.uid != Self.virtualUID } }
    var calSpeakers: [AudioDeviceInfo] { outputDevices.filter { config($0.uid).enabled } }
    var canCalibrate: Bool { !demo && calPhase == .idle && calSpeakers.count >= 2 && !micDevices.isEmpty }
    var calEstimate: Double { CalibrationRunner.estimatedSeconds(speakers: calSpeakers.count, mics: max(1, calMics.count)) }

    /// Opens the setup window: the test song plays through every enabled speaker so the volumes can be balanced by ear.
    func openCalibration() {
        guard canCalibrate else { return }
        error = nil; calError = nil; calReport = nil
        presetVolumes = Dictionary(uniqueKeysWithValues: calSpeakers.map { ($0.uid, deviceVolume($0.uid)) })
        if calMics.count != 1 || !calMics.isSubset(of: Set(micDevices.map(\.uid))) {
            if let m = micDevices.first(where: { $0.transport == .builtIn }) ?? micDevices.first { calMics = [m.uid] } else { calMics = [] }
        }
        stopEngine()
        calPhase = .setup
        startTestSong()
    }

    private func startTestSong() {
        testEngine?.stop(); testEngine = nil
        do {
            let song = try TestSound.load()
            let outs = calSpeakers.map { ($0, appliedDelayMs($0.uid), digitalVolume($0.uid)) }
            let e = try RouterEngine(inputs: [], shared: song, outputs: outs)
            try e.start()
            testEngine = e
        } catch { calError = error.localizedDescription }
    }

    /// Back to the volumes the speakers had when the window opened.
    func calUsePreset() { for (uid, v) in presetVolumes { setDeviceVolume(uid, v) } }
    /// A fresh start: everything at 50 %, to be balanced from scratch.
    func calStartFresh() { for d in calSpeakers { setDeviceVolume(d.uid, 0.5) } }
    var calVolumesChanged: Bool { calSpeakers.contains { abs(deviceVolume($0.uid) - (presetVolumes[$0.uid] ?? 1)) > 0.005 } }

    /// "Finish now": stop measuring after the current measurement and use the best setting found so far.
    func finishCalibrationEarly() {
        guard calPhase == .running, calControl.searching else { return }
        calControl.requestFinish()
        calFinishRequested = true
    }

    // MARK: Listening to before / after

    private var listenSong: LoopSource?
    @Published private(set) var calListening: Bool?        // nil = not playing, false = original, true = calibrated

    /// Plays the test song through the speakers with the original (false) or the calibrated (true) delays, switching live.
    func calListen(calibrated: Bool) {
        guard let r = calReport else { return }
        let delays = calibrated ? r.outcome.delaysMs : r.originalDelaysMs
        if let e = testEngine {
            for (i, uid) in r.speakerUIDs.enumerated() where i < delays.count { e.setDelay(uid: uid, ms: delays[i]) }
            calListening = calibrated
            return
        }
        do {
            let song = try listenSong ?? TestSound.load()
            listenSong = song
            let outs: [(AudioDeviceInfo, Double, Double)] = r.speakerUIDs.enumerated().compactMap { i, uid in
                guard let d = devices.first(where: { $0.uid == uid }), i < delays.count else { return nil }
                return (d, delays[i], digitalVolume(uid))
            }
            let e = try RouterEngine(inputs: [], shared: song, outputs: outs)
            try e.start()
            testEngine = e
            calListening = calibrated
        } catch { calError = error.localizedDescription }
    }

    func stopListening() {
        testEngine?.stop(); testEngine = nil
        calListening = nil
    }

    /// The user's verdict after listening to both. Kept (with the measured improvement) to see how the index relates to ears.
    @Published private(set) var calFeedbackGiven = false
    func recordFeedback(better: String) {
        guard let r = calReport else { return }
        var log = UserDefaults.standard.array(forKey: "calibration.feedback") as? [[String: Any]] ?? []
        log.append(["better": better, "measured": r.measuredImprovement ?? NSNull(), "date": Date().timeIntervalSince1970])
        UserDefaults.standard.set(log, forKey: "calibration.feedback")
        calFeedbackGiven = true
    }
    /// (agreeing, total) over the saved verdicts: "calibrated is better" agrees with a measured improvement.
    var feedbackAgreement: (agree: Int, total: Int) {
        let log = UserDefaults.standard.array(forKey: "calibration.feedback") as? [[String: Any]] ?? []
        var agree = 0, total = 0
        for e in log {
            guard let b = e["better"] as? String, b != "same", let m = e["measured"] as? Double else { continue }
            total += 1
            if (b == "calibrated") == (m > 0.02) { agree += 1 }
        }
        return (agree, total)
    }

    func closeCalibration() {
        calTask?.cancel(); calTask = nil
        testEngine?.stop(); testEngine = nil
        calListening = nil; calFeedbackGiven = false
        calPhase = .idle
        if running { tick() }
    }

    func backToCalibrationSetup() {
        calError = nil
        calListening = nil; calFeedbackGiven = false
        calPhase = .setup
        startTestSong()
    }

    func startMeasurement() {
        guard calPhase == .setup, !calMics.isEmpty else { return }
        calTask = Task {
            guard await ensureMicAccess() else { calError = error; calPhase = .failed; return }
            testEngine?.stop(); testEngine = nil
            calError = nil; calFraction = 0; calStatus = "준비 중…"
            calPhase = .running
            let speakers = calSpeakers.map { CalibrationSpeaker(device: $0, appliedDelayMs: appliedDelayMs($0.uid), volume: digitalVolume($0.uid)) }
            let mics = Array(micDevices.filter { calMics.contains($0.uid) }.prefix(1))
            let control = CalibrationControl()
            calControl = control
            calStarted = Date()
            calBestSoFar = nil; calCanFinishEarly = false; calFinishRequested = false; calRemaining = calEstimate
            let estimate = CalibrationRunner.estimatedSeconds(speakers: speakers.count, mics: mics.count,
                                                             maxDelayMs: (speakers.map(\.appliedDelayMs).max() ?? 0) + 50)
            do {
                let report = try await CalibrationRunner().run(speakers: speakers, mics: mics, control: control) { [weak self] text, frac in
                    Task { @MainActor in
                        guard let self else { return }
                        self.calStatus = text; self.calFraction = frac
                        let left = estimate - Date().timeIntervalSince(self.calStarted)
                        self.calRemaining = left > 3 ? left : nil
                        self.calBestSoFar = control.improvement
                        self.calCanFinishEarly = control.searching
                    }
                }
                calReport = report
                stopListening()
                calPhase = .done
            } catch is CancellationError {
            } catch {
                calError = error.localizedDescription
                calPhase = .failed
            }
        }
    }

    /// Makes the solved delays the current setting. Volumes are left exactly as the user set them.
    func applyCalibration() {
        guard let r = calReport else { return }
        let delays = r.outcome.delaysMs
        // Slider values are absolute lags; the router delays every speaker to the laggiest one, so lag_i = M − delay_i.
        let m = max(delays.max() ?? 0, calSpeakers.map { totalLag($0.uid) }.max() ?? 0)
        for (i, uid) in r.speakerUIDs.enumerated() where i < delays.count {
            var c = config(uid)
            c.auto = false
            c.manualLagMs = HapticPlanner.clamp(m - delays[i], limit: Self.maxDelayMs)
            outputs[uid] = c
        }
        pushDelays()
        scheduleSave()
        Haptics.major()
        closeCalibration()
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

    private func tick() {
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

    private func rebuildEngine() {
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
            let outs = outputDevices.filter { config($0.uid).enabled }
            guard !outs.isEmpty else { error = "출력 장치를 하나 이상 켜세요"; return }
            do {
                let e = try RouterEngine(inputs: ins, shared: shared, outputs: outs.map { ($0, appliedDelayMs($0.uid), digitalVolume($0.uid)) })
                try e.start()
                engine = e
                pushMixes()
                if !e.failures.isEmpty {
                    error = e.failures.map { "\($0.name) 출력 실패: \($0.message)" }.joined(separator: "\n")
                }
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
            "MacBook Pro 스피커": OutputConfig(enabled: true, volume: 0.9),
            "AirPods Pro": OutputConfig(enabled: true, volume: 0.7),
            "LG UltraFine": OutputConfig(enabled: true, auto: false, manualLagMs: 80, volume: 1),
            "Studio Display 스피커": OutputConfig(enabled: false, volume: 1),
        ]
        hwLatencyMs = ["MacBook Pro 스피커": 14, "AirPods Pro": 192, "LG UltraFine": 38, "Studio Display 스피커": 21,
                       AppModel.virtualUID: 5, "Scarlett 2i2 USB": 9]
        running = true
        capturing = true
        spatialOn = true
        outputs["AirPods Pro"]?.angleDeg = 120
        outputs["AirPods Pro"]?.aimOffsetDeg = 35
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var outputs: [String: OutputConfig]
        var spatialOn: Bool?
        var listenerHeadingDeg: Double?
    }
    /// Written immediately: the app quits as soon as the last window closes, so a debounce would drop the last change.
    private func scheduleSave() {
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
