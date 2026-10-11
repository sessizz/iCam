//
//  StreamPipeline.swift
//  iCam (iPhone)
//
//  Camera → encoder → network, with end-to-end congestion control.
//
//  The Mac acknowledges every frame after decoding it, which gives a round
//  trip and a delivered byte count per frame. RateController (Shared/) turns
//  them into the encoder's bitrate once per second; see there for the policy.
//
//  Wi-Fi hiccups never drop frames by themselves (the Mac smooths them out
//  with a small playout buffer). Only when the oldest unacknowledged frame
//  has waited far too long is the link really stuck: new camera frames are
//  then dropped *before* encoding. The encoder never sees a dropped frame,
//  so the reference chain stays intact and no key frame is needed.
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

    private struct InFlightFrame {
        let sequence: UInt32
        let sentAt: CFTimeInterval
        let bytes: Int
    }

    private struct State {
        var isStreaming = false
        var config: StreamConfig?
        var controller = RateController(policy: .wifi, startBitrate: 0, minBitrate: 0, frameRate: 30, now: 0)
        /// Sent but not yet acknowledged, oldest first.
        var inFlight: [InFlightFrame] = []
        // One-second statistics window.
        var windowStart: CFTimeInterval = 0
        var framesSent = 0
        var bytesSent = 0
        var bytesAcked = 0
        var framesDropped = 0
        var sourceFramesDropped = 0
        var rttSamples: [CFTimeInterval] = []
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
        let controller = RateController(policy: .for(transport), startBitrate: config.bitrate,
                                        minBitrate: minBitrate, frameRate: Double(ICam.frameRate), now: now)
        camera.captureQueue.async {
            self.encoder.configure(codec: config.codec, bitrate: config.bitrate)
            self.state.withLock {
                $0.isStreaming = true
                $0.config = config
                $0.controller = controller
                // Anything still in flight belongs to a previous stream.
                $0.inFlight.removeAll()
                $0.windowStart = now
                $0.framesSent = 0
                $0.bytesSent = 0
                $0.bytesAcked = 0
                $0.framesDropped = 0
                $0.sourceFramesDropped = 0
                $0.rttSamples.removeAll()
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
                s.bytesAcked += first.bytes
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
            let policy = s.controller.policy
            let stuck = s.inFlight.first.map { now - $0.sentAt > policy.maxQueueDelay } ?? false
            if stuck || s.inFlight.count >= policy.maxFramesInFlight {
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
            s.inFlight.append(InFlightFrame(sequence: frame.sequence, sentAt: now, bytes: bytes))
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

            let previous = s.controller.targetBitrate
            let evaluation = s.controller.evaluate(
                RateController.Window(elapsed: elapsed, bytesSent: s.bytesSent, framesSent: s.framesSent,
                                      bytesAcked: s.bytesAcked, roundTrips: s.rttSamples,
                                      framesDropped: s.framesDropped),
                ceiling: ceiling, now: now)
            let target = s.controller.targetBitrate
            let newBitrate: Int? = target != previous ? target : nil
            let oldestWait = s.inFlight.first.map { now - $0.sentAt } ?? 0

            let stats = PipelineStats(
                fps: Double(s.framesSent) / elapsed,
                bitrate: Int(Double(s.bytesSent * 8) / elapsed),
                targetBitrate: target,
                // No ack this window (a stall): the oldest frame's wait is a
                // lower bound on the round trip.
                latencyMs: (evaluation.medianRoundTrip ?? oldestWait) * 1000,
                queueDelayMs: evaluation.queueDelay * 1000,
                droppedFrames: s.framesDropped,
                sourceDroppedFrames: s.sourceFramesDropped)
            s.windowStart = now
            s.framesSent = 0
            s.bytesSent = 0
            s.bytesAcked = 0
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

    var currentBitrate: Int { state.withLock { $0.controller.targetBitrate } }
}
