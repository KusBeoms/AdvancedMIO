import Foundation
import MIOCore

/// What the result screen plots: when each speaker's sound reaches the microphone, with the old and the new delays.
struct CalibrationCharts {
    let names: [String]
    let beforeMs: [Double]        // relative to the earliest speaker
    let afterMs: [Double]
}

extension CalibrationReport {
    func charts() -> CalibrationCharts? {
        let n = speakerNames.count
        guard n > 0, arrivalsMs.count == n, originalDelaysMs.count == n, delaysMs.count == n else { return nil }
        func rel(_ d: [Double]) -> [Double] {
            let t = (0..<n).map { arrivalsMs[$0] + d[$0] }
            let low = t.min() ?? 0
            return t.map { $0 - low }
        }
        return CalibrationCharts(names: speakerNames, beforeMs: rel(originalDelaysMs), afterMs: rel(delaysMs))
    }

    /// Why this result can or cannot be trusted, in plain words.
    var confidenceNotes: [String] {
        var notes: [String] = []
        notes.append(wholeSong ? "노래 전체를 \(segments)개 구간으로 나눠 한 번에 계산했습니다" : "빠른 측정: 음량 패턴 \(segments)개 구간으로 계산했습니다 (곡 전체를 쓰면 더 정확합니다)")
        if let f = fit {
            notes.append("수식 모델이 녹음의 \(Int((f * 100).rounded()))%를 설명 — \(f < 0.5 ? "낮아서 도착 시간이 덜 정확할 수 있습니다" : "충분히 높습니다")")
        }
        return notes
    }
}

// MARK: - Calibration flow

extension AppModel {
    func selectCalMic(_ uid: String) { calMics = [uid] }

    var calSpeakers: [AudioDeviceInfo] { enabledOutputs }
    var canCalibrate: Bool { !demo && calPhase == .idle && calSpeakers.count >= 2 && !micDevices.isEmpty }
    var calEstimate: Double { CalibrationRunner.estimatedSeconds(speakers: calSpeakers.count, mics: max(1, calMics.count), wholeSong: calWholeSong) }

    /// Opens the setup window: the test song plays through every enabled speaker so the volumes can be balanced by ear.
    func openCalibration() {
        guard canCalibrate else { return }
        error = nil; calError = nil; calReport = nil; calCharts = nil
        presetVolumes = Dictionary(uniqueKeysWithValues: calSpeakers.map { ($0.uid, deviceVolume($0.uid)) })
        if calMics.count != 1 || !calMics.isSubset(of: Set(micDevices.map(\.uid))) {
            if let m = micDevices.first(where: { $0.transport == .builtIn }) ?? micDevices.first { calMics = [m.uid] } else { calMics = [] }
        }
        stopEngine()
        calPhase = .setup
        startTestSong()
    }

    func startTestSong() {
        testEngine?.stop(); testEngine = nil
        do {
            let song = try TestSound.load()
            let outs = calSpeakers.map { ($0, syncDelayMs($0.uid), digitalVolume($0.uid)) }
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
            let speakers = calSpeakers.map { CalibrationSpeaker(device: $0, appliedDelayMs: syncDelayMs($0.uid), volume: digitalVolume($0.uid)) }
            let mics = Array(micDevices.filter { calMics.contains($0.uid) }.prefix(1))
            calStarted = Date()
            calRemaining = calEstimate
            let estimate = calEstimate
            do {
                let report = try await CalibrationRunner().run(speakers: speakers, mics: mics, wholeSong: calWholeSong) { [weak self] text, frac in
                    Task { @MainActor in
                        guard let self else { return }
                        self.calStatus = text; self.calFraction = frac
                        let left = estimate - Date().timeIntervalSince(self.calStarted)
                        self.calRemaining = left > 3 ? left : nil
                    }
                }
                calReport = report
                calCharts = report.charts()
                recordCalibration(report)
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
        let delays = r.delaysMs
        // Slider values are absolute lags; the router delays every speaker to the laggiest one, so lag_i = M − delay_i.
        let m = max(delays.max() ?? 0, calSpeakers.map { totalLag($0.uid) }.max() ?? 0)
        for (i, uid) in r.speakerUIDs.enumerated() where i < delays.count {
            var c = config(uid)
            c.auto = false
            c.manualLagMs = HapticPlanner.clamp(m - delays[i], limit: Self.maxDelayMs)
            c.hwBaselineMs = hwLatencyMs[uid]
            outputs[uid] = c
        }
        if let id = calRecordID, let i = calHistory.firstIndex(where: { $0.id == id }) {
            calHistory[i].applied = true
            Store.saveHistory(calHistory)
        }
        pushDelays()
        scheduleSave()
        updateLatencyAlerts()
        Haptics.major()
        closeCalibration()
    }

    // MARK: Listening to before / after

    /// Plays the test song through the speakers with the original (false) or the calibrated (true) delays, switching live.
    func calListen(calibrated: Bool) {
        guard let r = calReport else { return }
        let delays = calibrated ? r.delaysMs : r.originalDelaysMs
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
    func recordFeedback(better: String) {
        guard let r = calReport else { return }
        var log = UserDefaults.standard.array(forKey: "calibration.feedback") as? [[String: Any]] ?? []
        log.append(["better": better, "measured": r.improvement ?? NSNull(), "date": Date().timeIntervalSince1970])
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

    // MARK: History

    private func recordCalibration(_ r: CalibrationReport) {
        let rec = CalibrationRecord(date: Date(), roomName: calRoomName, speakerUIDs: r.speakerUIDs, speakerNames: r.speakerNames,
                                    originalDelaysMs: r.originalDelaysMs, calibratedDelaysMs: r.delaysMs,
                                    measuredBefore: r.spreadBeforeMs, measuredAfter: r.spreadAfterMs, unit: "ms",
                                    hwLatencyMs: hwLatencyMs.filter { r.speakerUIDs.contains($0.key) }, applied: false)
        calRecordID = rec.id
        calHistory.append(rec)
        Store.saveHistory(calHistory)
    }

    func setCalRoomName(_ name: String) {
        calRoomName = name
        UserDefaults.standard.set(name, forKey: "calibration.roomName")
        if let id = calRecordID, let i = calHistory.firstIndex(where: { $0.id == id }) {
            calHistory[i].roomName = name
            Store.saveHistory(calHistory)
        }
    }

    func deleteCalibrationRecord(_ id: UUID) {
        calHistory.removeAll { $0.id == id }
        Store.saveHistory(calHistory)
    }

    /// Why the last applied calibration probably no longer fits (different speakers, or a device whose latency moved).
    var calibrationStaleReason: String? {
        guard let last = calHistory.last(where: \.applied) else { return nil }
        let now = Set(calSpeakers.map(\.uid)), then = Set(last.speakerUIDs)
        if now != then { return "스피커 구성이 마지막 캘리브레이션(\(last.roomName)) 때와 다릅니다" }
        for d in calSpeakers {
            if let was = last.hwLatencyMs[d.uid], let nowMs = hwLatencyMs[d.uid], LatencyWatch.hasDrifted(from: was, to: nowMs) {
                return "\(d.name)의 하드웨어 지연이 \(Int(was.rounded())) → \(Int(nowMs.rounded())) ms 로 달라졌습니다"
            }
        }
        return nil
    }
}
