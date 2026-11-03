import MIOCore

// Spatial audio: each enabled output is a point on a circle around the listener (see SpatialView).
extension AppModel {
    /// Where this speaker stands on the circle: the user's placement, else its default slot.
    func spatialAngle(_ uid: String) -> Double {
        if let a = config(uid).angleDeg { return a }
        let list = enabledOutputs
        guard let i = list.firstIndex(where: { $0.uid == uid }) else { return 0 }
        return SpatialPanner.defaultAngles(count: list.count)[i]
    }
    func spatialAimOffset(_ uid: String) -> Double { config(uid).aimOffsetDeg }
    func spatialRadius(_ uid: String) -> Double { config(uid).radius }
    func spatialDistanceMeters(_ uid: String) -> Double { SpatialPanner.distanceMeters(radius: spatialRadius(uid)) }

    /// Nearer speakers wait for the farthest one so every speaker's sound reaches the listener together.
    func spatialDelayMs(_ uid: String) -> Double {
        guard spatialOn else { return 0 }
        let farthest = enabledOutputs.map { spatialDistanceMeters($0.uid) }.max() ?? 0
        return SpatialPanner.alignDelayMs(distance: spatialDistanceMeters(uid), farthest: farthest)
    }

    func setSpatialOn(_ on: Bool) {
        spatialOn = on
        pushDelays()        // distances change the delays too
        scheduleSave()
    }
    func setListenerHeading(_ deg: Double) {
        listenerHeadingDeg = SpatialPanner.normalized(deg)
        pushMixes()
        scheduleSave()
    }
    /// Moves a speaker on the stage: its angle and its distance from the listener (0…1) together.
    func setSpatialPlace(_ uid: String, angle: Double, radius: Double) {
        var c = config(uid)
        c.radius = min(1, max(0, radius))
        // On top of the listener the angle means nothing; keep the old one so dragging back out starts from there.
        if c.radius > 0.02 || c.angleDeg == nil { c.angleDeg = SpatialPanner.normalized(angle) }
        commit(uid, c)
    }
    func setSpatialAimOffset(_ uid: String, _ deg: Double) {
        var c = config(uid); c.aimOffsetDeg = SpatialPanner.normalized(deg)
        commit(uid, c)
    }
    func resetSpatial() {
        for uid in outputs.keys { outputs[uid]?.angleDeg = nil; outputs[uid]?.aimOffsetDeg = 0; outputs[uid]?.radius = 1 }
        listenerHeadingDeg = 0
        pushDelays()
        scheduleSave()
    }

    /// Sends every speaker its placement mix (identity when spatial audio is off). The calibration test engine is
    /// left alone: it must measure the plain stereo signal.
    func pushMixes() {
        guard let engine else { return }
        for d in enabledOutputs {
            let m = spatialOn
                ? SpatialPanner.mix(positionDeg: spatialAngle(d.uid), radius: spatialRadius(d.uid),
                                    aimOffsetDeg: spatialAimOffset(d.uid), headingDeg: listenerHeadingDeg)
                : SpatialMix.identity
            engine.setMix(uid: d.uid, m)
        }
    }
}
