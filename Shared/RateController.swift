//
//  RateController.swift
//  Shared (used by the iPhone app; simulated in Tests/RateControlTests.swift)
//
//  Chooses the video bitrate from what the Mac acknowledges. Pure logic, no
//  clocks or I/O, so it can be driven by a link simulation in tests.
//
//  * The lowest round trip of the last 10 s is the link's baseline; how far
//    the typical (median) round trip sits above it is the queueing delay.
//  * Congestion means a queue that keeps building while the link delivers
//    clearly less than was sent. Wi-Fi hiccups (power saving, scans,
//    retransmissions) delay acknowledgements, but the link catches up
//    afterwards, so they don't count. On congestion the bitrate drops to just
//    below what the link delivered, which is remembered for a minute as the
//    link's capacity.
//  * A quiet scene encodes far below the target. The link's speed is then
//    unknown, and lowering the target wouldn't relieve it anyway, so delays
//    seen while the stream is that far below the target never lower it.
//  * Below the ceiling (or the remembered capacity) the bitrate recovers
//    quickly; above the remembered capacity it is probed only slowly, and
//    only while the scene actually needs the bits.
//

import Foundation

struct RateController {

    /// How a link is treated.
    struct Policy: Equatable {
        /// New frames are dropped before encoding once the oldest
        /// unacknowledged frame has waited this long (the link is stuck).
        var maxQueueDelay: Double
        /// Hard cap on frames in flight.
        var maxFramesInFlight: Int
        /// Queueing delay above which a building queue counts as congestion.
        var congestedDelay: Double
        /// Queueing delay below which the bitrate may rise.
        var clearDelay: Double

        static let usb = Policy(maxQueueDelay: 0.25, maxFramesInFlight: 8, congestedDelay: 0.05, clearDelay: 0.02)
        // Wi-Fi delivers in bursts; 100–300 ms hiccups are normal there.
        static let wifi = Policy(maxQueueDelay: 0.6, maxFramesInFlight: 20, congestedDelay: 0.12, clearDelay: 0.045)

        static func `for`(_ transport: TransportKind) -> Policy {
            transport == .usb ? .usb : .wifi
        }
    }

    /// What happened during one statistics window (about a second).
    struct Window {
        var elapsed: Double
        var bytesSent: Int
        var framesSent: Int
        var bytesAcked: Int
        /// Round trips (send → decoded on the Mac → ack) of frames acked in
        /// this window.
        var roundTrips: [Double]
        /// Camera frames dropped before encoding.
        var framesDropped: Int
    }

    struct Evaluation {
        var medianRoundTrip: Double?
        var queueDelay: Double
    }

    let policy: Policy
    let minBitrate: Int
    let frameRate: Double
    private(set) var targetBitrate: Int

    private var recentMinimumRoundTrips: [Double] = []
    private var congestedWindows = 0
    private var lastDecrease = -1e9
    private var lastIncrease: Double
    private var previousBytesSent = 0
    private var previousBytesAcked = 0
    private var previousQueueDelay = 0.0
    /// Delivered bit rates of the last three windows.
    private var recentDeliveredRates: [Double] = []
    private var capacity: Double?
    private var capacityMeasuredAt = -1e9

    init(policy: Policy, startBitrate: Int, minBitrate: Int, frameRate: Double, now: Double) {
        self.policy = policy
        self.targetBitrate = startBitrate
        self.minBitrate = minBitrate
        self.frameRate = frameRate
        self.lastIncrease = now
    }

    mutating func evaluate(_ window: Window, ceiling: Int, now: Double) -> Evaluation {
        let samples = window.roundTrips.sorted()
        let median = samples.isEmpty ? nil : samples[samples.count / 2]
        if let fastest = samples.first {
            recentMinimumRoundTrips.append(fastest)
            if recentMinimumRoundTrips.count > 10 { recentMinimumRoundTrips.removeFirst() }
        }
        var queueDelay = 0.0
        if let median, let baseline = recentMinimumRoundTrips.min() {
            queueDelay = max(0, median - baseline)
        }

        // Two windows, so a hiccup's late acknowledgements are counted once
        // the link has caught up.
        let sentOverTwo = window.bytesSent + previousBytesSent
        let ackedOverTwo = window.bytesAcked + previousBytesAcked
        previousBytesSent = window.bytesSent
        previousBytesAcked = window.bytesAcked
        recentDeliveredRates.append(Double(window.bytesAcked) * 8 / window.elapsed)
        if recentDeliveredRates.count > 3 { recentDeliveredRates.removeFirst() }

        // What the encoder produces per frame, at the frame rate: the scene's
        // demand, independent of frames dropped before encoding.
        let demand = window.framesSent > 0
            ? Double(window.bytesSent) * 8 / Double(window.framesSent) * frameRate : 0
        let appLimited = window.framesSent > 0 && demand < 0.6 * Double(targetBitrate)
        let behind = sentOverTwo > 0 && Double(ackedOverTwo) < 0.85 * Double(sentOverTwo)
        let rising = queueDelay > previousQueueDelay + 0.01
        previousQueueDelay = queueDelay
        if capacity != nil, now - capacityMeasuredAt > 60 { capacity = nil }

        var target = Double(targetBitrate)
        if window.framesDropped > 0 {
            // Stuck for longer than maxQueueDelay. If the stream was using
            // the link and it fell behind, that's congestion; otherwise
            // usually a radio stall: back off only a little, once.
            if !appLimited, behind || rising, now - lastDecrease > 1 {
                target = cutToCapacity(target, now: now)
                lastDecrease = now
            } else if now - lastDecrease > 2 {
                target = max(Double(minBitrate), target * 0.9)
                lastDecrease = now
            }
            congestedWindows = 0
        } else if queueDelay > policy.congestedDelay, !appLimited, rising || behind {
            // A queue is building: act on the second such window, or at once
            // when it is long and the link fell behind.
            congestedWindows += 1
            if congestedWindows >= 2 || (queueDelay > 2 * policy.congestedDelay && behind),
               now - lastDecrease > 1 {
                target = cutToCapacity(target, now: now)
                lastDecrease = now
                congestedWindows = 0
            }
        } else {
            if queueDelay < policy.congestedDelay { congestedWindows = 0 }
            if queueDelay < policy.clearDelay, target < Double(ceiling), now - lastDecrease > 2 {
                let cap = capacity.map { min(Double(ceiling), $0) } ?? Double(ceiling)
                if target < cap, now - lastIncrease >= 1 {
                    let factor = target < 0.5 * cap ? 1.25 : 1.08
                    target = min(cap, target * factor + 100_000)
                    lastIncrease = now
                } else if target >= cap, !appLimited, now - lastIncrease >= 3 {
                    target = min(Double(ceiling), target * 1.05)
                    lastIncrease = now
                }
            }
        }
        targetBitrate = Int(min(target, Double(ceiling)))
        return Evaluation(medianRoundTrip: median, queueDelay: queueDelay)
    }

    /// To 85% of the best rate the link delivered in the last three windows
    /// (the best one, so a stall's empty window doesn't count as the link's
    /// speed), and at least 15% down.
    private mutating func cutToCapacity(_ target: Double, now: Double) -> Double {
        let delivered = recentDeliveredRates.max() ?? 0
        capacity = delivered
        capacityMeasuredAt = now
        return max(Double(minBitrate), min(target * 0.85, delivered * 0.85))
    }
}
