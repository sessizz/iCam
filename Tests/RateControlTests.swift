//
//  RateControlTests.swift
//
//  Drives the iPhone's RateController with a frame-level simulation of the
//  link to the Mac:
//
//    camera (30 fps) → encoder (output = min(target × 0.9, what the scene
//    needs), follows a new target after 0.3 s, key frame every 30 s)
//    → FIFO link with a capacity and "stalls" (radio pauses: nothing moves)
//    → Mac decodes and acks (one-way delay each way).
//
//  Frames are dropped before encoding exactly like StreamPipeline does.
//  The scenarios cover what users actually see: a good Wi-Fi network with
//  short hiccups, a bad one with a quiet scene (the case where the bitrate
//  used to collapse to the 1.5 Mbps floor), a slow link, a link whose
//  capacity collapses, one long stall, and USB.
//
//  Run (any platform):
//    swiftc -parse-as-library Shared/ICamProtocol.swift Shared/MessageFraming.swift Shared/RateController.swift \
//      Tests/RateControlTests.swift -o /tmp/rate-tests && /tmp/rate-tests
//

import Foundation

@main
enum RateControlTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        if !condition() {
            failures += 1
            print("FAIL (line \(line)): \(message)")
        }
    }

    static func main() {
        goodWiFi()
        badWiFiQuietScene()
        badWiFiQuietThenMotion()
        slowLink()
        capacityCollapse()
        oneLongStall()
        usb()
        if failures == 0 {
            print("All rate control tests passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }

    // MARK: Scenarios

    static func goodWiFi() {
        let run = simulate(stalls: stalls(seed: 11, length: 0.1...0.35, gap: 2...6, until: 120),
                           demand: { $0 < 60 ? 2.5e6 : 30e6 })
        report("good Wi-Fi, short hiccups, quiet then moving", run)
        expect(run.dropped == 0, "good Wi-Fi: no dropped frames (\(run.dropped))")
        expect(run.targets(from: 10, to: 120).min()! >= 15_000_000, "good Wi-Fi: bitrate stays high")
    }

    /// The reported case: frequent Wi-Fi stalls while the person sits still.
    static func badWiFiQuietScene() {
        let run = simulate(duration: 300, stalls: stalls(seed: 12, length: 0.15...0.6, gap: 1...4, until: 300),
                           demand: { _ in 1e6 })
        report("bad Wi-Fi, quiet scene", run)
        expect(run.dropped == 0, "bad Wi-Fi quiet: no dropped frames (\(run.dropped))")
        expect(run.targets(from: 10, to: 300).min()! >= 10_000_000,
               "bad Wi-Fi quiet: bitrate doesn't collapse (min \(run.targets(from: 10, to: 300).min()!))")
    }

    static func badWiFiQuietThenMotion() {
        let run = simulate(duration: 300, stalls: stalls(seed: 13, length: 0.15...0.6, gap: 1...4, until: 300),
                           demand: { $0 < 200 ? 1e6 : 30e6 })
        report("bad Wi-Fi, quiet then moving", run)
        expect(run.dropped <= 3, "bad Wi-Fi motion: at most a few dropped frames (\(run.dropped))")
        expect(run.targets(from: 200, to: 300).min()! >= 12_000_000, "bad Wi-Fi motion: full quality when moving")
    }

    static func slowLink() {
        let run = simulate(capacity: { _ in 6e6 }, demand: { $0 < 60 ? 2.5e6 : 30e6 })
        report("6 Mbps link, quiet then moving", run)
        let settled = run.targets(from: 70, to: 120)
        let average = Double(settled.reduce(0, +)) / Double(settled.count)
        expect(run.dropped <= 60, "slow link: dropping only while adapting (\(run.dropped))")
        expect(run.dropTimes.filter { $0 >= 70 }.isEmpty, "slow link: no drops once adapted")
        expect(average > 4_000_000 && average < 7_500_000, "slow link: settles near capacity (\(Int(average)))")
    }

    static func capacityCollapse() {
        let run = simulate(capacity: { $0 < 60 ? 40e6 : 5e6 }, demand: { _ in 30e6 })
        report("40 → 5 Mbps at 60 s, moving", run)
        let settled = run.targets(from: 75, to: 120)
        let average = Double(settled.reduce(0, +)) / Double(settled.count)
        expect(run.dropped <= 120, "collapse: bounded drops (\(run.dropped))")
        expect(run.dropTimes.filter { $0 >= 75 }.isEmpty, "collapse: no drops once adapted")
        expect(average > 3_500_000 && average < 6_500_000, "collapse: settles near capacity (\(Int(average)))")
    }

    static func oneLongStall() {
        let run = simulate(stalls: [(30, 1.6)], demand: { _ in 13e6 })
        report("one 1.6 s stall", run)
        expect(run.dropped <= 45, "long stall: frames dropped only during the stall (\(run.dropped))")
        expect(run.targets(from: 60, to: 120).min()! >= 15_000_000, "long stall: bitrate recovers")
    }

    static func usb() {
        let run = simulate(policy: .usb, start: 14_000_000, ceiling: 20_000_000, capacity: { _ in 300e6 },
                           oneWay: 0.0005, demand: { _ in 13e6 })
        report("USB", run)
        expect(run.dropped == 0, "USB: no dropped frames")
        expect(run.history.last!.target == 20_000_000, "USB: reaches the ceiling")
    }

    // MARK: Simulation

    /// 64-bit LCG, identical to the Python model used to tune the controller.
    struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        mutating func uniform(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * next()
        }
    }

    static func stalls(seed: UInt64, length: ClosedRange<Double>, gap: ClosedRange<Double>,
                       until duration: Double) -> [(start: Double, length: Double)] {
        var random = Random(state: seed)
        var result: [(start: Double, length: Double)] = []
        var t = 1.0
        while t < duration {
            result.append((t, random.uniform(length)))
            t += random.uniform(gap)
        }
        return result
    }

    struct Run {
        var dropped = 0
        var dropTimes: [Double] = []
        var history: [(time: Double, target: Int, sentRate: Double)] = []

        func targets(from start: Double, to end: Double) -> [Int] {
            history.filter { $0.time >= start && $0.time < end }.map(\.target)
        }
    }

    static func report(_ name: String, _ run: Run) {
        let targets = run.history.map(\.target)
        print(String(format: "%@: %d dropped, target min %.1f / end %.1f Mbps", name, run.dropped,
                     Double(targets.dropFirst(10).min() ?? 0) / 1e6, Double(targets.last ?? 0) / 1e6))
    }

    static func simulate(policy: RateController.Policy = .wifi, start: Int = 10_000_000,
                         ceiling: Int = 16_000_000, duration: Double = 120,
                         capacity: (Double) -> Double = { _ in 60e6 }, oneWay: Double = 0.004,
                         stalls: [(start: Double, length: Double)] = [], demand: (Double) -> Double,
                         efficiency: Double = 0.9, lag: Double = 0.3, seed: UInt64 = 1) -> Run {
        var random = Random(state: seed)
        var controller = RateController(policy: policy, startBitrate: start, minBitrate: 1_500_000,
                                        frameRate: 30, now: 0)
        let fps = 30.0
        let dt = 1 / fps
        var applied = Double(start)
        var pendingTargets: [(time: Double, target: Int)] = []
        var linkFreeAt = 0.0
        var inFlight: [(sequence: Int, sentAt: Double, bytes: Int)] = []
        var acks: [(time: Double, sequence: Int)] = []
        var sequence = 0
        var bytesSent = 0, framesSent = 0, bytesAcked = 0, framesDropped = 0
        var roundTrips: [Double] = []
        var windowStart = 0.0
        var nextKeyFrame = 0.0
        var run = Run()

        func stallEnd(_ t: Double) -> Double? {
            for stall in stalls where stall.start <= t && t < stall.start + stall.length {
                return stall.start + stall.length
            }
            return nil
        }

        var index = 0
        while true {
            let t = Double(index) * dt
            if t >= duration { break }
            index += 1

            while let ack = acks.first, ack.time <= t {
                acks.removeFirst()
                while let frame = inFlight.first, frame.sequence <= ack.sequence {
                    inFlight.removeFirst()
                    bytesAcked += frame.bytes
                    if frame.sequence == ack.sequence { roundTrips.append(ack.time - frame.sentAt) }
                }
            }
            while let pending = pendingTargets.first, pending.time <= t {
                pendingTargets.removeFirst()
                applied = Double(pending.target)
            }

            let stuck = inFlight.first.map { t - $0.sentAt > policy.maxQueueDelay } ?? false
            if stuck || inFlight.count >= policy.maxFramesInFlight {
                framesDropped += 1
                run.dropped += 1
                run.dropTimes.append(t)
            } else {
                let rate = min(applied * efficiency, demand(t))
                var size = rate / fps / 8 * random.uniform(0.7...1.3)
                if t >= nextKeyFrame {
                    size = max(size, applied * efficiency / fps / 8) * 6
                    nextKeyFrame = t + 30
                }
                sequence += 1
                var startTx = max(t, linkFreeAt)
                if let end = stallEnd(startTx) { startTx = end }
                var done = startTx + size * 8 / capacity(startTx)
                if let end = stallEnd(done) { done = end + (done - startTx) * 0.1 }
                linkFreeAt = done
                var ackAt = done + oneWay + 0.003 + oneWay
                if let end = stallEnd(ackAt) { ackAt = end }
                inFlight.append((sequence, t, Int(size)))
                var position = acks.count
                while position > 0 && acks[position - 1].time > ackAt { position -= 1 }
                acks.insert((ackAt, sequence), at: position)
                bytesSent += Int(size)
                framesSent += 1
            }

            if t - windowStart >= 1 {
                let elapsed = t - windowStart
                let previous = controller.targetBitrate
                _ = controller.evaluate(
                    RateController.Window(elapsed: elapsed, bytesSent: bytesSent, framesSent: framesSent,
                                          bytesAcked: bytesAcked, roundTrips: roundTrips,
                                          framesDropped: framesDropped),
                    ceiling: ceiling, now: t)
                if controller.targetBitrate != previous {
                    pendingTargets.append((t + lag, controller.targetBitrate))
                }
                run.history.append((t, controller.targetBitrate, Double(bytesSent) * 8 / elapsed))
                bytesSent = 0
                framesSent = 0
                bytesAcked = 0
                framesDropped = 0
                roundTrips.removeAll()
                windowStart = t
            }
        }
        return run
    }
}
