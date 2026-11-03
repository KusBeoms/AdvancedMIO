import Foundation
import MIOCore

// Presets: a named snapshot of the whole routing setup.
extension AppModel {
    var activePreset: Preset? { presets.first { $0.id == activePresetID } }

    /// Saves the current setup under `name` (replacing a preset of the same name).
    func savePreset(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // Remember what is actually heard: the device's own volume where it has one.
        var snapshot = outputs
        for uid in snapshot.keys { snapshot[uid]?.volume = deviceVolume(uid) }
        let preset = Preset(id: presets.first { $0.name == name }?.id ?? UUID(), name: name, outputs: snapshot,
                            spatialOn: spatialOn, listenerHeadingDeg: listenerHeadingDeg)
        if let i = presets.firstIndex(where: { $0.id == preset.id }) { presets[i] = preset } else { presets.append(preset) }
        activePresetID = preset.id
        persistPresets()
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if activePresetID == id { activePresetID = nil }
        persistPresets()
    }

    /// Switches to a preset: devices on/off, lag, volume, EQ and placement. Devices the preset does not know are turned off.
    func applyPreset(_ id: UUID) {
        guard let p = presets.first(where: { $0.id == id }) else { return }
        var next = outputs
        for uid in next.keys where p.outputs[uid] == nil { next[uid]?.enabled = false }
        for (uid, saved) in p.outputs {
            var c = saved
            if !c.auto { c.hwBaselineMs = hwLatencyMs[uid] ?? c.hwBaselineMs }    // the lag was chosen for how it behaves now
            next[uid] = c
        }
        outputs = next
        spatialOn = p.spatialOn
        listenerHeadingDeg = p.listenerHeadingDeg
        for (uid, c) in p.outputs {
            guard devices.contains(where: { $0.uid == uid }) else { continue }
            setDeviceVolume(uid, c.volume)
        }
        activePresetID = id
        dismissedLatency = [:]
        pushDelays()
        pushEQs()
        scheduleSave()
        persistPresets()
        updateLatencyAlerts()
        if running { rebuildEngine() }
        Haptics.major()
    }

    /// Applies the preset whose name best matches `query` (URL / CLI). False if none does.
    @discardableResult
    func applyPreset(named query: String) -> Bool {
        guard let i = NameMatch.best(query, in: presets.map(\.name)) else {
            error = "'\(query)' 프리셋이 없습니다"
            return false
        }
        applyPreset(presets[i].id)
        return true
    }

    private func persistPresets() {
        guard !demo else { return }
        Store.savePresets(presets)
        UserDefaults.standard.set(activePresetID?.uuidString, forKey: "presets.active")
    }
}
