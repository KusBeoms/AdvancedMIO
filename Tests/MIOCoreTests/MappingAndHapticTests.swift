import XCTest
@testable import MIOCore

final class MappingAndHapticTests: XCTestCase {
    func testHapticEdges() {
        XCTAssertEqual(HapticPlanner.event(from: 5, to: 0), .edge)
        XCTAssertEqual(HapticPlanner.event(from: 995, to: 1000), .edge)
        XCTAssertEqual(HapticPlanner.event(from: 0, to: 0), .none)
    }
    func testHapticMajorEvery100() {
        XCTAssertEqual(HapticPlanner.event(from: 99, to: 100), .major)
        XCTAssertEqual(HapticPlanner.event(from: 100, to: 99), .major)
        XCTAssertEqual(HapticPlanner.event(from: 199, to: 201), .major)
        XCTAssertEqual(HapticPlanner.event(from: 50, to: 450), .major)
    }
    func testHapticTickEvery10() {
        XCTAssertEqual(HapticPlanner.event(from: 109, to: 110), .tick)
        XCTAssertEqual(HapticPlanner.event(from: 111, to: 119), .none)
        XCTAssertEqual(HapticPlanner.event(from: 125, to: 135), .tick)
    }
    func testHapticCountsWhileDraggingFullRange() {
        var ticks = 0, majors = 0, edges = 0
        var prev = 0.0
        for v in 1...1000 {
            switch HapticPlanner.event(from: prev, to: Double(v)) {
            case .tick: ticks += 1
            case .major: majors += 1
            case .edge: edges += 1
            case .none: break
            }
            prev = Double(v)
        }
        XCTAssertEqual(majors, 9)           // 100…900
        XCTAssertEqual(ticks, 90)           // 10-ms boundaries that are not 100-ms boundaries
        XCTAssertEqual(edges, 1)            // reaching 1000
    }
    func testClamp() {
        XCTAssertEqual(HapticPlanner.clamp(-5), 0)
        XCTAssertEqual(HapticPlanner.clamp(1000.4), 1000)
        XCTAssertEqual(HapticPlanner.clamp(1234), 1000)
        XCTAssertEqual(HapticPlanner.clamp(12.6), 13)
    }

    func testExtractStereoInterleaved() {
        var buf: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]    // 4 frames × 2ch
        var l = [Float](repeating: 0, count: 4), r = l
        buf.withUnsafeMutableBufferPointer { p in
            let refs = [BufferRef(data: p.baseAddress, channels: 2)]
            refs.withUnsafeBufferPointer { rp in
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rr in
                    ChannelMapping.extractStereo(rp, frames: 4, left: lp.baseAddress!, right: rr.baseAddress!) } } }
        }
        XCTAssertEqual(l, [1, 3, 5, 7]); XCTAssertEqual(r, [2, 4, 6, 8])
    }
    func testExtractStereoTwoMonoBuffersAndMono() {
        var a: [Float] = [1, 2], b: [Float] = [10, 20]
        var l = [Float](repeating: 0, count: 2), r = l
        a.withUnsafeMutableBufferPointer { pa in b.withUnsafeMutableBufferPointer { pb in
            let refs = [BufferRef(data: pa.baseAddress, channels: 1), BufferRef(data: pb.baseAddress, channels: 1)]
            refs.withUnsafeBufferPointer { rp in l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rr in
                ChannelMapping.extractStereo(rp, frames: 2, left: lp.baseAddress!, right: rr.baseAddress!) } } } } }
        XCTAssertEqual(l, [1, 2]); XCTAssertEqual(r, [10, 20])
        a.withUnsafeMutableBufferPointer { pa in
            let refs = [BufferRef(data: pa.baseAddress, channels: 1)]
            refs.withUnsafeBufferPointer { rp in l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rr in
                ChannelMapping.extractStereo(rp, frames: 2, left: lp.baseAddress!, right: rr.baseAddress!) } } } }
        XCTAssertEqual(l, [1, 2]); XCTAssertEqual(r, [1, 2])
    }
    func testExtractStereoNoBuffersGivesSilence() {
        var l: [Float] = [9, 9], r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rr in
            ChannelMapping.extractStereo(UnsafeBufferPointer(start: nil, count: 0), frames: 2, left: lp.baseAddress!, right: rr.baseAddress!) } }
        XCTAssertEqual(l, [0, 0]); XCTAssertEqual(r, [0, 0])
    }
    func testFillOutputMultichannelAndMono() {
        let L: [Float] = [1, 2], R: [Float] = [10, 20]
        var out = [Float](repeating: 0, count: 8)   // 2 frames × 4ch
        out.withUnsafeMutableBufferPointer { p in
            let refs = [BufferRef(data: p.baseAddress, channels: 4)]
            refs.withUnsafeBufferPointer { rp in L.withUnsafeBufferPointer { lp in R.withUnsafeBufferPointer { rr in
                ChannelMapping.fillOutput(rp, frames: 2, left: lp.baseAddress!, right: rr.baseAddress!) } } }
        }
        XCTAssertEqual(out, [1, 10, 1, 10, 2, 20, 2, 20])
        var mono = [Float](repeating: 0, count: 2)
        mono.withUnsafeMutableBufferPointer { p in
            let refs = [BufferRef(data: p.baseAddress, channels: 1)]
            refs.withUnsafeBufferPointer { rp in L.withUnsafeBufferPointer { lp in R.withUnsafeBufferPointer { rr in
                ChannelMapping.fillOutput(rp, frames: 2, left: lp.baseAddress!, right: rr.baseAddress!) } } }
        }
        XCTAssertEqual(mono, [5.5, 11])
        // Two stereo buffers (e.g. 2 streams): each gets L/R in turn, k restarts per channel index across buffers.
        var s1 = [Float](repeating: 0, count: 2), s2 = s1
        s1.withUnsafeMutableBufferPointer { p1 in s2.withUnsafeMutableBufferPointer { p2 in
            let refs = [BufferRef(data: p1.baseAddress, channels: 1), BufferRef(data: p2.baseAddress, channels: 1)]
            refs.withUnsafeBufferPointer { rp in L.withUnsafeBufferPointer { lp in R.withUnsafeBufferPointer { rr in
                ChannelMapping.fillOutput(rp, frames: 2, left: lp.baseAddress!, right: rr.baseAddress!) } } } } }
        XCTAssertEqual(s1, [1, 2]); XCTAssertEqual(s2, [10, 20])
    }
}
