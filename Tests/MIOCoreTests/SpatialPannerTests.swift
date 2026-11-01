import XCTest
@testable import MIOCore

final class SpatialPannerTests: XCTestCase {
    func testLeftSpeakerCarriesLeftChannel() {
        let m = SpatialPanner.mix(positionDeg: -90)
        XCTAssertEqual(m.ll, 1, accuracy: 1e-5)
        XCTAssertEqual(m.lr, 0, accuracy: 1e-5)
    }

    func testRightSpeakerCarriesRightChannel() {
        let m = SpatialPanner.mix(positionDeg: 90)
        XCTAssertEqual(m.ll, 0, accuracy: 1e-5)
        XCTAssertEqual(m.lr, 1, accuracy: 1e-5)
    }

    func testFrontCentreKeepsMonoLevel() {
        let m = SpatialPanner.mix(positionDeg: 0)
        XCTAssertEqual(m.ll + m.lr, 1, accuracy: 1e-5)     // L = R = x  →  feed = x
        XCTAssertEqual(m.ll, m.lr, accuracy: 1e-5)
    }

    func testBothChannelsOfADeviceGetTheSameFeed() {
        let m = SpatialPanner.mix(positionDeg: 40, aimOffsetDeg: 30, headingDeg: 10)
        XCTAssertEqual(m.ll, m.rl); XCTAssertEqual(m.lr, m.rr)
    }

    func testRearIsQuieterThanFront() {
        let front = SpatialPanner.mix(positionDeg: 0), rear = SpatialPanner.mix(positionDeg: 180)
        XCTAssertLessThan(rear.ll + rear.lr, front.ll + front.lr)
        XCTAssertEqual(rear.ll + rear.lr, 0.65, accuracy: 1e-5)
    }

    func testListenerHeadingRotatesTheStage() {
        // Listener turns to the right: the speaker that was on the right is now straight ahead.
        let m = SpatialPanner.mix(positionDeg: 90, headingDeg: 90)
        XCTAssertEqual(m.ll, m.lr, accuracy: 1e-5)
        // …and the one that was in front is now on the listener's left.
        let f = SpatialPanner.mix(positionDeg: 0, headingDeg: 90)
        XCTAssertEqual(f.ll, 1, accuracy: 1e-5)
    }

    func testSpeakerTurnedAwayGetsQuieter() {
        let at = SpatialPanner.mix(positionDeg: 0, aimOffsetDeg: 0)
        let away = SpatialPanner.mix(positionDeg: 0, aimOffsetDeg: 180)
        let side = SpatialPanner.mix(positionDeg: 0, aimOffsetDeg: 90)
        XCTAssertEqual((away.ll + away.lr) / (at.ll + at.lr), Float(1 - SpatialPanner.directivity), accuracy: 1e-5)
        XCTAssertLessThan(away.ll, side.ll)
        XCTAssertLessThan(side.ll, at.ll)
    }

    func testNeverAmplifiesMonoMaterial() {
        for p in stride(from: -180.0, through: 180, by: 7) {
            for a in stride(from: -180.0, through: 180, by: 30) {
                let m = SpatialPanner.mix(positionDeg: p, aimOffsetDeg: a)
                XCTAssertLessThanOrEqual(m.ll + m.lr, 1 + 1e-5)
            }
        }
    }

    func testDefaultAngles() {
        XCTAssertEqual(SpatialPanner.defaultAngles(count: 0), [])
        XCTAssertEqual(SpatialPanner.defaultAngles(count: 1), [0])
        XCTAssertEqual(SpatialPanner.defaultAngles(count: 2), [-45, 45])
        XCTAssertEqual(SpatialPanner.defaultAngles(count: 4), [-45, 45, 135, -135])
    }

    func testNormalized() {
        XCTAssertEqual(SpatialPanner.normalized(190), -170, accuracy: 1e-9)
        XCTAssertEqual(SpatialPanner.normalized(-190), 170, accuracy: 1e-9)
        XCTAssertEqual(SpatialPanner.normalized(180), 180, accuracy: 1e-9)
        XCTAssertEqual(SpatialPanner.normalized(720), 0, accuracy: 1e-9)
    }
}
