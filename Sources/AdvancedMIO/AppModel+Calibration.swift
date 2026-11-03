import Foundation
import MIOCore

/// What the result screen plots: the summed response at the microphone with the original and the calibrated delays.
struct CalibrationCharts {
    let names: [String]                         // the speakers the microphone heard
    let before: RoomOptimizer.ResponseView
    let after: RoomOptimizer.ResponseView
}

extension CalibrationReport {
    /// Speakers the microphone heard (the identified room only contains these), in speaker order.
    var audibleIndices: [Int] { speakerNames.indices.filter { !excluded.contains(speakerNames[$0]) } }

    func charts() -> CalibrationCharts? {
        guard let mic = room.first else { return nil }
        let idx = audibleIndices
        guard !idx.isEmpty, idx.allSatisfy({ $0 < originalDelaysMs.count && $0 < outcome.delaysMs.count }),
              let b = RoomOptimizer.view(of: mic, delaysMs: idx.map { originalDelaysMs[$0] }),
              let a = RoomOptimizer.view(of: mic, delaysMs: idx.map { outcome.delaysMs[$0] }) else { return nil }
        return CalibrationCharts(names: idx.map { speakerNames[$0] }, before: b, after: a)
    }

    /// Why this result can or cannot be trusted, in plain words.
    var confidenceNotes: [String] {
        var notes: [String] = []
        if let b = measuredBefore, let a = measuredAfter {
            notes.append("스피커 사이 도착 시간 차이 \(String(format: "%.1f", b)) ms → \(String(format: "%.1f", a)) ms (마이크 위치 기준, 측정 모델로 계산)")
        }
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
    var calEstimate: Double { CalibrationRunner.estimatedSeconds(speakers: calSpeakers.count, mics: max(1, calMics.count)) }

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

    /// "Finish now": stop measuring after the current measurement and use the best setting found so far.
    func finishCalibrationEarly() {
        guard calPhase == .running, calControl.searching else { return }
        calControl.requestFinish()
        calFinishRequested = true
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
            let speakers = calSpeakers.map { CalibrationSpeaker(device: $0, appliedDelayMs: syncDelayMs($0.uid), volume: digitalVolume($0.uid)) }
            let mics = Array(micDevices.filter { calMics.contains($0.uid) }.prefix(1))
            let control = CalibrationControl()
            calControl = control
            calStarted = Date()
            calBestSoFar = nil; calCanFinishEarly = false; calFinishRequested = false; calRemaining = calEstimate
            let estimate = CalibrationRunner.estimatedSeconds(speakers: speakers.count, mics: mics.count)
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
                calCharts = report.charts()
                if let room = report.room.first { Task.detached(priority: .utility) { DevStore.saveRoom(room) } }
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
        let delays = r.outcome.delaysMs
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

    // MARK: History

    private func recordCalibration(_ r: CalibrationReport) {
        let rec = CalibrationRecord(date: Date(), roomName: calRoomName, speakerUIDs: r.speakerUIDs, speakerNames: r.speakerNames,
                                    originalDelaysMs: r.originalDelaysMs, calibratedDelaysMs: r.outcome.delaysMs,
                                    measuredBefore: r.measuredBefore, measuredAfter: r.measuredAfter, unit: "ms",
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
