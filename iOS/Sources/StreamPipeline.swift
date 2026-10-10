//
//  StreamPipeline.swift
//  iCam (iPhone)
//
//  Camera → encoder → network, with end-to-end congestion control.
//
//  The Mac acknowledges every frame after decoding it, which gives a round
//  trip time per frame. The controller is delay based:
//
//   * The lowest recent round trip is the link's baseline; how far the
//     typical (median) round trip sits above it is the queueing delay.
//     Only a queue that keeps building means the stream is faster than the
//     link: then the bitrate goes down. A clean link raises it again.
//   * Wi-Fi delivers in bursts (power saving, retransmissions, other
//     traffic). Hiccups of 100–300 ms are normal there and are *not*
//     congestion, so they never drop frames by themselves; the Mac smooths
//     them out with a small playout buffer.
//   * Only when the oldest unacknowledged frame has waited far too long is
//     the link really stuck: new camera frames are then dropped *before*
//     encoding. The encoder never sees a dropped frame, so the reference
//     chain stays intact and no key frame is needed to recover.
//

import AVFoundation
import QuartzCore
import os

struct PipelineStats: Equatable {
    var fps: Double = 0
    var bitrate: Int = 0
    var targetBitrate: Int = 0
    /// Median frame round trip (iPhone → Mac decode → ack) in the last second.
    var latencyMs: Double = 0
    /// Median queueing delay above the link's baseline round trip.
    var queueDelayMs: Double = 0
    /// Camera frames dropped before encoding in the last second.
    var droppedFrames = 0
    /// Frames the camera or the encoder dropped themselves in the last second.
    var sourceDroppedFrames = 0
}

final class StreamPipeline: CameraCaptureDelegate {

    let camera = CameraCapture()

    /// Writes framed bytes to the active Mac connection. Thread safe.
    var send: ((Data) -> Void)?
    /// Called on an arbitrary queue when camera state changes.
    var onCameraStateChange: (() -> Void)?
    /// Called on an arbitrary queue about once per second while streaming.
    var onStats: ((PipelineStats) -> Void)?

    private let log = Logger(subsystem: "app.icam", category: "pipeline")
    private let encoder = VideoEncoder()
    private let minBitrate = 1_500_000

    /// How the controller treats a link.
    struct LinkPolicy: Equatable {
        /// Frames are dropped before encoding once the oldest unacknowledged
        /// frame has waited this long (the link is stuck, not just bursty).
        var maxQueueDelay: CFTimeInterval
        /// Hard cap on frames in flight.
        var maxFramesInFlight: Int
        /// Median queueing delay that counts as a building queue.
        var congestedDelay: CFTimeInterval
        /// Median queueing delay below which the bitrate may rise.
        var clearDelay: CFTimeInterval

        static let usb = LinkPolicy(maxQueueDelay: 0.25, maxFramesInFlight: 8,
                                    congestedDelay: 0.05, clearDelay: 0.02)
        static let wifi = LinkPolicy(maxQueueDelay: 0.6, maxFramesInFlight: 20,
                                     congestedDelay: 0.12, clearDelay: 0.045)

        static func `for`(_ transport: TransportKind) -> LinkPolicy {
            transport == .usb ? .usb : .wifi
        }
    }

    private struct InFlightFrame {
        let sequence: UInt32
        let sentAt: CFTimeInterval
    }

    private struct State {
        var isStreaming = false
        var config: StreamConfig?
        var policy = LinkPolicy.wifi
        var targetBitrate = 0
        /// Sent but not yet acknowledged, oldest first.
        var inFlight: [InFlightFrame] = []
        /// Per-second minimum round trips of the last 10 seconds.
        var recentMinimumRTTs: [CFTimeInterval] = []
        // One-second statistics window.
        var windowStart: CFTimeInterval = 0
        var framesSent = 0
        var bytesSent = 0
        var framesDropped = 0
        var sourceFramesDropped = 0
        var rttSamples: [CFTimeInterval] = []
        var congestedWindows = 0
        var lastBitrateDecrease: CFTimeInterval = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        camera.delegate = self
        encoder.onEncodedFrame = { [weak self] frame in
            self?.deliver(frame)
        }
        encoder.onDroppedFrame = { [weak self] in
            self?.state.withLock { $0.sourceFramesDropped += 1 }
        }
    }

    var isStreaming: Bool { state.withLock { $0.isStreaming } }

    // MARK: Control

    func start(config: StreamConfig, settings: CameraSettings, transport: TransportKind) {
        let now = CACurrentMediaTime()
        let policy = LinkPolicy.for(transport)
        camera.captureQueue.async {
            self.encoder.configure(codec: config.codec, bitrate: config.bitrate)
            self.state.withLock {
                $0.isStreaming = true
                $0.config = config
                $0.policy = policy
                $0.targetBitrate = config.bitrate
                // Anything still in flight belongs to a previous stream.
                $0.inFlight.removeAll()
                $0.recentMinimumRTTs.removeAll()
                $0.windowStart = now
                $0.framesSent = 0
                $0.bytesSent = 0
                $0.framesDropped = 0
                $0.sourceFramesDropped = 0
                $0.rttSamples.removeAll()
                $0.congestedWindows = 0
                $0.lastBitrateDecrease = now
            }
        }
        camera.start(settings: settings)
        log.info("Streaming started over \(transport.rawValue, privacy: .public): \(config.codec.rawValue, privacy: .public) \(config.bitrate) bps")
    }

    func stop() {
        state.withLock { $0.isStreaming = false }
        camera.stop()
        camera.captureQueue.async {
            self.encoder.invalidate()
        }
        onStats?(PipelineStats())
        log.info("Streaming stopped")
    }

    func requestKeyFrame() {
        camera.captureQueue.async { self.encoder.requestKeyFrame() }
    }

    func apply(settings: CameraSettings) {
        camera.apply(settings)
    }

    func acknowledge(sequence: UInt32) {
        let now = CACurrentMediaTime()
        state.withLock { s in
            // Acks arrive in order; everything up to `sequence` is done.
            // (Sequence numbers wrap, so compare distances; acks from a
            // previous stream are older than every frame in flight.)
            while let first = s.inFlight.first, sequence &- first.sequence < 1 << 31 {
                if first.sequence == sequence, s.rttSamples.count < 120 {
                    s.rttSamples.append(now - first.sentAt)
                }
                s.inFlight.removeFirst()
            }
        }
    }

    // MARK: CameraCaptureDelegate

    func cameraCapture(_ capture: CameraCapture, didOutput pixelBuffer: CVPixelBuffer,
                       presentationTime: CMTime) {
        let now = CACurrentMediaTime()
        let shouldEncode = state.withLock { s -> Bool in
            guard s.isStreaming else { return false }
            let stuck = s.inFlight.first.map { now - $0.sentAt > s.policy.maxQueueDelay } ?? false
            if stuck || s.inFlight.count >= s.policy.maxFramesInFlight {
                s.framesDropped += 1
                return false
            }
            return true
        }
        if shouldEncode {
            encoder.encode(pixelBuffer, presentationTime: presentationTime)
        }
        evaluateWindow(now: now)
    }

    func cameraCaptureDidDropFrame(_ capture: CameraCapture) {
        state.withLock { $0.sourceFramesDropped += 1 }
    }

    func cameraCaptureStateDidChange(_ capture: CameraCapture) {
        onCameraStateChange?()
    }

    // MARK: Output

    private func deliver(_ frame: EncodedFrame) {
        guard let send else { return }
        let now = CACurrentMediaTime()
        let formatMessage = frame.format.map { MessageFramer.frame(.videoFormat, payload: $0.encoded()) }
        let bytes = frame.message.count + (formatMessage?.count ?? 0)
        if let formatMessage { send(formatMessage) }
        state.withLock { s in
            s.inFlight.append(InFlightFrame(sequence: frame.sequence, sentAt: now))
            s.framesSent += 1
            s.bytesSent += bytes
        }
        send(frame.message)
    }

    /// Runs once per second on the capture queue: bitrate adaptation + stats.
    private func evaluateWindow(now: CFTimeInterval) {
        let thermal = ProcessInfo.processInfo.thermalState
        let minBitrate = self.minBitrate
        let result: (stats: PipelineStats, newBitrate: Int?)? = state.withLock { s in
            guard s.isStreaming, let config = s.config else { return nil }
            let elapsed = now - s.windowStart
            guard elapsed >= 1 else { return nil }

            let thermalFactor: Double
            switch thermal {
            case .critical: thermalFactor = 0.4
            case .serious: thermalFactor = 0.6
            default: thermalFactor = 1
            }
            let ceiling = max(minBitrate, Int(Double(config.maxBitrate) * thermalFactor))

            // Round trips of this window: median = typical, minimum feeds the
            // baseline (lowest of the last 10 s; it follows slow drift).
            let samples = s.rttSamples.sorted()
            let median = samples.isEmpty ? nil : samples[samples.count / 2]
            if let fastest = samples.first {
                s.recentMinimumRTTs.append(fastest)
                if s.recentMinimumRTTs.count > 10 { s.recentMinimumRTTs.removeFirst() }
            }
            let baseline = s.recentMinimumRTTs.min()
            let queueDelay = median.flatMap { median in baseline.map { max(0, median - $0) } } ?? 0
            // Frames still waiting count too: an ack that never comes is the
            // strongest congestion signal.
            let oldestWait = s.inFlight.first.map { now - $0.sentAt } ?? 0
            let delay = max(queueDelay, oldestWait > s.policy.congestedDelay * 2 ? oldestWait : 0)

            var target = s.targetBitrate
            if s.framesDropped > 0 {
                // The link was stuck: back off firmly.
                target = max(minBitrate, Int(Double(target) * 0.7))
                s.lastBitrateDecrease = now
                s.congestedWindows = 0
            } else if delay > s.policy.congestedDelay {
                // A queue is building. Back off gently, and only if it
                // persists, so a single slow second doesn't cost quality.
                s.congestedWindows += 1
                if s.congestedWindows >= 2 {
                    target = max(minBitrate, Int(Double(target) * 0.85))
                    s.lastBitrateDecrease = now
                    s.congestedWindows = 0
                }
            } else {
                s.congestedWindows = 0
                if delay < s.policy.clearDelay, now - s.lastBitrateDecrease > 2, target < ceiling {
                    target = min(ceiling, Int(Double(target) * 1.1) + 200_000)
                }
            }
            target = min(target, ceiling)
            var newBitrate: Int?
            if target != s.targetBitrate {
                s.targetBitrate = target
                newBitrate = target
            }

            let stats = PipelineStats(
                fps: Double(s.framesSent) / elapsed,
                bitrate: Int(Double(s.bytesSent * 8) / elapsed),
                targetBitrate: s.targetBitrate,
                latencyMs: (median ?? 0) * 1000,
                queueDelayMs: delay * 1000,
                droppedFrames: s.framesDropped,
                sourceDroppedFrames: s.sourceFramesDropped)
            s.windowStart = now
            s.framesSent = 0
            s.bytesSent = 0
            s.framesDropped = 0
            s.sourceFramesDropped = 0
            s.rttSamples.removeAll(keepingCapacity: true)
            return (stats, newBitrate)
        }
        guard let result else { return }
        if let newBitrate = result.newBitrate {
            encoder.setBitrate(newBitrate)
            log.info("Bitrate → \(newBitrate)")
        }
        onStats?(result.stats)
    }

    var currentBitrate: Int { state.withLock { $0.targetBitrate } }
}
