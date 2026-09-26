import Foundation

/// Exponentially weighted packet-loss estimator over a sliding window.
/// Not thread-safe by design: owners guard it (receivers already serialize
/// pump-side state behind their packet locks).
public struct LossEstimator {
    public private(set) var lossRate: Double = 0
    public private(set) var burstLossRate: Double = 0
    private var window: Int
    private var recent: [Bool] = []
    private var recentCount = 0
    private var lossCount = 0

    /// - Parameters:
    ///   - window: packets in the sliding window (default ~1 s of audio).
    public init(window: Int = 47) {
        self.window = max(4, window)
    }

    public mutating func record(sequence: UInt64, receivedSequence: UInt64) {
        let gap = sequence > receivedSequence ? Int(sequence - receivedSequence) : 0
        recordExpected(count: gap + 1, lost: gap)
    }

    public mutating func recordExpected(count: Int, lost: Int) {
        let clampedLost = max(0, min(lost, count))
        for _ in 0..<clampedLost {
            push(lost: true)
        }
        push(lost: false)
        lossCount += clampedLost
    }

    private mutating func push(lost: Bool) {
        if recent.count == window {
            let dropped = recent.removeFirst()
            if dropped { lossCount = max(0, lossCount - 1) }
        }
        recent.append(lost)
        recentCount += 1
        if recentCount >= window {
            lossRate = Double(lossCount) / Double(recent.count)
        }
    }

    /// Longest run of consecutive losses currently in the window — the burst
    /// length the jitter buffer must be prepared to bridge.
    public mutating func currentBurstLength() -> Int {
        var longest = 0
        var run = 0
        for l in recent where l {
            run += 1
            longest = max(longest, run)
        }
        if recent.last == false { run = 0 }
        burstLossRate = Double(longest) / Double(window)
        return longest
    }
}

/// Adaptive jitter buffer for a packetized receiver: chooses a target depth
/// in packets from the measured loss/burst profile, with bounded step changes
/// so the buffer never lurches audibly.
///
/// Design:
///   • Base depth = ceil(packetsPerSecond × 40 ms) — enough for normal jitter.
///   • Every observed burst raises the floor toward max(base, burst + 1).
///   • Sustained loss ≥ 2 % nudges the depth up one packet per decision,
///     capped at 8 packets (~170 ms @ 48 kHz).
///   • With clean audio (no loss, no bursts) for 20 s the depth decays one
///     packet per 10 s back toward base — latency is returned gradually.
public struct AdaptiveJitterBuffer {
    public let packetsPerSecond: Double
    public private(set) var depthPackets: Int
    public private(set) var baseDepth: Int
    public private(set) var maxDepth: Int
    private var cleanSeconds: Double = 0
    private var decayDebt: Double = 0
    private var lossTicks: Int = 0

    public init(packetsPerSecond: Double, minDepth: Int = 2, maxDepth: Int = 8) {
        self.packetsPerSecond = packetsPerSecond
        self.baseDepth = max(minDepth, Int((packetsPerSecond * 0.040).rounded(.up)))
        self.maxDepth = max(baseDepth + 1, maxDepth)
        self.depthPackets = baseDepth
    }

    /// Feeds one measurement cycle and returns the depth to use now.
    public mutating func update(lostPackets: Int, receivedPackets: Int, nowSeconds: Double) -> Int {
        let lost = max(0, lostPackets)
        if lost > 0 {
            lossTicks += 1
            cleanSeconds = 0
            // Rising edge: raise one packet per cycle with loss, up to cap.
            if depthPackets < maxDepth {
                depthPackets += 1
            }
        } else {
            let total = max(receivedPackets + lost, 1)
            if Double(lossTicks) / Double(total) < 0.02 {
                cleanSeconds += nowSeconds
                // Decay one packet per 10 s of clean audio.
                decayDebt += nowSeconds
                while decayDebt >= 10.0, depthPackets > baseDepth {
                    depthPackets -= 1
                    decayDebt -= 10.0
                }
            } else {
                cleanSeconds = 0
            }
            lossTicks = 0
        }
        return depthPackets
    }
}
