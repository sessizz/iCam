//
//  StreamPipeline.swift
//  iCam (iPhone)
//
//  Camera → encoder → network, with end-to-end congestion control.
//
//  The Mac acknowledges every frame after it has been decoded. If too many
//  frames are unacknowledged the link (or the Mac) can't keep up, so new
//  camera frames are dropped *before* encoding. Because the encoder never
//  sees a dropped frame, the reference chain stays intact and no key frame is
//  needed to recover – the Mac simply shows the previous frame a bit longer.
//  Sustained drops lower the bitrate; a clean link slowly raises it again.
//

import AVFoundation
import QuartzCore
import os

struct PipelineStats: Equatable {
    var fps: Double = 0
    var bitrate: Int = 0
    var targetBitrate: Int = 0
    var latencyMs: Double = 0
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

    /// Frames that may be in flight (sent but not yet acknowledged) before
    /// new camera frames are dropped. 4 frames ≈ 133 ms at 30 fps.
    private let maxFramesInFlight: UInt32 = 4
    private let minBitrate = 1_500_000

    private struct State {
        var isStreaming = false
        var config: StreamConfig?
        var targetBitrate = 0
        var lastSentSequence: UInt32 = 0
        var lastAckedSequence: UInt32 = 0
        var sendTimes: [UInt32: CFTimeInterval] = [:]
        // One-second statistics window.
        var windowStart: CFTimeInterval = 0
        var framesSent = 0
        var bytesSent = 0
        var framesDropped = 0
        var latencySum: CFTimeInterval = 0
        var latencyCount = 0
        var lastBitrateDecrease: CFTimeInterval = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        camera.delegate = self
        encoder.onEncodedFrame = { [weak self] frame in
            self?.deliver(frame)
        }
    }

    var isStreaming: Bool { state.withLock { $0.isStreaming } }

    // MARK: Control

    func start(config: StreamConfig, settings: CameraSettings) {
        let now = CACurrentMediaTime()
        camera.captureQueue.async {
            self.encoder.configure(codec: config.codec, bitrate: config.bitrate)
            self.state.withLock {
                $0.isStreaming = true
                $0.config = config
                $0.targetBitrate = config.bitrate
                // Anything still in flight belongs to a previous stream.
                $0.lastAckedSequence = $0.lastSentSequence
                $0.sendTimes.removeAll()
                $0.windowStart = now
                $0.framesSent = 0
                $0.bytesSent = 0
                $0.framesDropped = 0
                $0.latencySum = 0
                $0.latencyCount = 0
                $0.lastBitrateDecrease = now
            }
        }
        camera.start(settings: settings)
        log.info("Streaming started: \(config.codec.rawValue, privacy: .public) \(config.bitrate) bps")
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
            // Ignore stale acks (sequence numbers wrap, so compare distance).
            let ahead = sequence &- s.lastAckedSequence
            guard ahead > 0, ahead < 1 << 31 else { return }
            s.lastAckedSequence = sequence
            if let sentAt = s.sendTimes.removeValue(forKey: sequence) {
                s.latencySum += now - sentAt
                s.latencyCount += 1
            }
            if s.sendTimes.count > 120 {
                s.sendTimes = s.sendTimes.filter { $0.key &- sequence < 1 << 31 }
            }
        }
    }

    // MARK: CameraCaptureDelegate

    func cameraCapture(_ capture: CameraCapture, didOutput pixelBuffer: CVPixelBuffer,
                       presentationTime: CMTime) {
        let now = CACurrentMediaTime()
        let shouldEncode = state.withLock { s -> Bool in
            guard s.isStreaming else { return false }
            let inFlight = s.lastSentSequence &- s.lastAckedSequence
            if inFlight >= maxFramesInFlight {
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

    func cameraCaptureStateDidChange(_ capture: CameraCapture) {
        onCameraStateChange?()
    }

    // MARK: Output

    private func deliver(_ frame: EncodedFrame) {
        guard let send else { return }
        let now = CACurrentMediaTime()
        var bytes = frame.message.count
        if let format = frame.format {
            let formatMessage = MessageFramer.frame(.videoFormat, payload: format.encoded())
            bytes += formatMessage.count
            send(formatMessage)
        }
        state.withLock { s in
            s.lastSentSequence = frame.sequence
            s.sendTimes[frame.sequence] = now
            s.framesSent += 1
            s.bytesSent += bytes
        }
        send(frame.message)
    }

    /// Runs once per second on the capture queue: bitrate adaptation + stats.
    private func evaluateWindow(now: CFTimeInterval) {
        let thermal = ProcessInfo.processInfo.thermalState
        var newBitrate: Int?
        let stats: PipelineStats? = state.withLock { s in
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

            var target = s.targetBitrate
            if s.framesDropped > 0 {
                target = max(minBitrate, Int(Double(target) * 0.7))
                s.lastBitrateDecrease = now
            } else if now - s.lastBitrateDecrease > 4, target < ceiling {
                target = min(ceiling, Int(Double(target) * 1.08) + 100_000)
            }
            target = min(target, ceiling)
            if target != s.targetBitrate {
                s.targetBitrate = target
                newBitrate = target
            }

            let stats = PipelineStats(
                fps: Double(s.framesSent) / elapsed,
                bitrate: Int(Double(s.bytesSent * 8) / elapsed),
                targetBitrate: s.targetBitrate,
                latencyMs: s.latencyCount > 0 ? s.latencySum / Double(s.latencyCount) * 1000 : 0)
            s.windowStart = now
            s.framesSent = 0
            s.bytesSent = 0
            s.framesDropped = 0
            s.latencySum = 0
            s.latencyCount = 0
            return stats
        }
        if let newBitrate {
            encoder.setBitrate(newBitrate)
            log.info("Bitrate → \(newBitrate)")
        }
        if let stats { onStats?(stats) }
    }

    var currentBitrate: Int { state.withLock { $0.targetBitrate } }
}
