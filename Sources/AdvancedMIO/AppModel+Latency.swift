import Foundation
import MIOCore

/// A device whose reported latency moved away from what its manual lag was set against.
struct LatencyAlert: Identifiable, Equatable {
    var id: String { uid }
    let uid: String
    let name: String
    let fromMs: Double
    let toMs: Double
}

// Latency watch: every few seconds the devices' reported latency is read again. A device whose lag was set by hand
// (not auto) and whose latency has since changed — typically Bluetooth after a codec switch — is flagged in the window.
// Nothing is changed automatically.
extension AppModel {
    /// Re-reads the reported latency of every output. Auto devices follow it right away.
    func refreshLatencies() {
        guard !demo else { return }
        var next = hwLatencyMs
        for d in outputDevices { if let ms = HAL.outputLatencyMs(d.id) { next[d.uid] = ms } }
        let moved = next.contains { abs((hwLatencyMs[$0.key] ?? -1) - $0.value) > 0.01 }
        if moved {
            hwLatencyMs = next
            pushDelays()
        }
        updateLatencyAlerts()
    }

    func updateLatencyAlerts() {
        guard latencyWarningsEnabled else {
            if !latencyAlerts.isEmpty { latencyAlerts = [] }
            return
        }
        var alerts: [LatencyAlert] = []
        for d in enabledOutputs {
            let c = config(d.uid)
            guard !c.auto, let now = hwLatencyMs[d.uid] else { continue }
            guard let base = c.hwBaselineMs else {            // saved before this feature: adopt today's value as the reference
                outputs[d.uid]?.hwBaselineMs = now
                scheduleSave()
                continue
            }
            let reference = dismissedLatency[d.uid] ?? base
            if LatencyWatch.hasDrifted(from: reference, to: now) {
                alerts.append(LatencyAlert(uid: d.uid, name: d.name, fromMs: base, toMs: now))
            }
        }
        if alerts != latencyAlerts { latencyAlerts = alerts }
    }

    /// Hides this warning until the latency moves again.
    func dismissLatencyAlert(_ uid: String) {
        if let now = hwLatencyMs[uid] { dismissedLatency[uid] = now }
        updateLatencyAlerts()
    }

    func setLatencyWarnings(_ on: Bool) {
        latencyWarningsEnabled = on
        UserDefaults.standard.set(on, forKey: "latencyWarnings")
        dismissedLatency = [:]
        updateLatencyAlerts()
    }
}
