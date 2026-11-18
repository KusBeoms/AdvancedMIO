import Foundation

/// Smooths out bursty arrivals (Bluetooth delivers several packets at once, then nothing for a while) so the router's
/// input ring is written at a steady pace. A fixed cushion of `target` blocks is kept; the cushion grows after an
/// underrun and shrinks again after a calm half minute. Pure value type: the caller owns the lock and the clock.
public struct JitterBuffer {
    public struct Block {
        public var left: [Float]
        public var right: [Float]
        public init(left: [Float], right: [Float]) { self.left = left; self.right = right }
    }

    public enum Output {
        case priming            // still filling the cushion: play nothing yet
        case underrun           // the cushion ran dry: play silence, rebuffer
        case block(Block)
    }

    public let minTarget: Int
    public let maxTarget: Int
    public private(set) var target: Int
    public private(set) var underruns = 0
    public private(set) var dropped = 0
    private var blocks: [Block] = []
    private var primed = false
    private var calmTicks = 0
    private let calmTicksBeforeShrink: Int

    /// `calmSeconds` is how long without an underrun before the cushion shrinks by one block.
    public init(target: Int = 3, minTarget: Int = 2, maxTarget: Int = 16, calmSeconds: Double = 30) {
        self.minTarget = minTarget
        self.maxTarget = maxTarget
        self.target = min(maxTarget, max(minTarget, target))
        calmTicksBeforeShrink = max(1, Int(calmSeconds / AudioFraming.blockSeconds))
    }

    public var depth: Int { blocks.count }

    public mutating func push(_ block: Block) {
        blocks.append(block)
        // Far more than the cushion: the sender's clock runs fast or a burst arrived. Drop the oldest audio, not the newest.
        if blocks.count > target + 3 {
            let excess = blocks.count - (target + 1)
            blocks.removeFirst(excess)
            dropped += excess
        }
    }

    /// Called once per block period by the playout clock.
    public mutating func pop() -> Output {
        if !primed {
            guard blocks.count >= target else { return .priming }
            primed = true
        }
        guard !blocks.isEmpty else {
            primed = false
            underruns += 1
            target = min(maxTarget, target + 1)
            calmTicks = 0
            return .underrun
        }
        calmTicks += 1
        if calmTicks >= calmTicksBeforeShrink {
            calmTicks = 0
            if target > minTarget { target -= 1 }
        }
        return .block(blocks.removeFirst())
    }

    /// Playout speed relative to nominal (within ±1 %): above 1 drains a surplus, below 1 lets a shortage rebuild.
    /// This absorbs the small clock difference between the two Macs without ever dropping audio.
    public var playoutRate: Double {
        guard primed else { return 1 }
        // Measured just after pop: a healthy cushion now contains one block fewer.
        let error = Double(blocks.count - (target - 1))
        return 1 + max(-0.01, min(0.01, error * 0.004))
    }
}
