import CoreAudio
import Foundation

/// `AdvancedMIO --probe`: headless self-test of the CoreAudio layer (used by CI and for bug reports).
enum Probe {
    static func run() {
        let devices = HAL.allDevices()
        print("devices: \(devices.count)")
        for d in devices {
            let rate = HAL.nominalSampleRate(d.id).map { String(format: "%.0f Hz", $0) } ?? "?"
            let lat = HAL.outputLatencyMs(d.id).map { String(format: "%.1f ms", $0) } ?? "-"
            var fmt = "n/a"
            if d.isOutput { fmt = (try? HAL.validateFloatIO(d.id, scope: kAudioObjectPropertyScopeOutput)).map { _ in "float32 ok" } ?? "NOT float32" }
            print("- \(d.name) [\(d.transport.label)] in=\(d.inputChannels) out=\(d.outputChannels) rate=\(rate) hwLatency=\(lat) outFormat=\(fmt)")
        }
        guard let input = devices.first(where: { $0.isInput }),
              let output = devices.first(where: { $0.isOutput && $0.uid != input.uid }) else {
            print("loopback: skipped (needs one input device and a different output device)")
            return
        }
        do {
            let engine = try RouterEngine(inputs: [input], outputs: [(output, OutputConfig(enabled: true, delayMs: 250, volume: 0))])
            try engine.start()
            Thread.sleep(forTimeInterval: 2)
            engine.setDelay(uid: output.uid, ms: 1000)
            Thread.sleep(forTimeInterval: 1)
            engine.diagnostics().forEach { print("  " + $0) }
            let healthy = engine.isHealthy
            engine.stop()
            print("loopback: \(input.name) → \(output.name), delay 250→1000 ms: \(healthy ? "OK (callbacks fired, audio moved)" : "FAILED (no callbacks)")")
            if !healthy { exit(1) }
        } catch {
            print("loopback: FAILED \(error.localizedDescription)")
            exit(1)
        }
    }
}
