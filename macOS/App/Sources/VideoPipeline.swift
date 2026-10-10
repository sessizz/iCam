//
//  VideoPipeline.swift
//  iCam (Mac)
//
//  decoded iPhone frames → 1920×1080 420v → virtual camera + preview.
//

import CoreMedia
import CoreVideo
import QuartzCore
import VideoToolbox
import os

enum PortraitFraming: String, CaseIterable, Identifiable {
    /// Crop to fill the 16:9 frame (no bars).
    case fill
    /// Show the whole picture with black bars.
    case fit

    var id: String { rawValue }
}

struct StreamStats: Equatable {
    var fps: Double = 0
    var bitrate: Double = 0
    var rttMs: Double = 0
    var width = 0
    var height = 0
    var codec: VideoCodec?
}

/// Scales/crops arbitrary frames to the virtual camera's 1920×1080.
final class FrameConformer {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var framing: PortraitFraming?

    private let width = VirtualCamera.width
    private let height = VirtualCamera.height

    func conform(_ buffer: CVPixelBuffer, framing: PortraitFraming) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
           CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            return buffer // Zero-copy fast path (landscape).
        }
        if session == nil {
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        }
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                    attributes as CFDictionary, &pool)
        }
        guard let session, let pool else { return nil }
        if framing != self.framing {
            let mode = framing == .fill ? kVTScalingMode_Trim : kVTScalingMode_Letterbox
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: mode)
            self.framing = framing
        }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let output else { return nil }
        CVBufferPropagateAttachments(buffer, output)
        guard VTPixelTransferSessionTransferImage(session, from: buffer, to: output) == noErr else { return nil }
        return output
    }
}

/// Confined to `PhoneConnection.queue` (only `framing` is touched from
/// elsewhere, behind a lock).
final class VideoPipeline: @unchecked Sendable {
    /// Receives every conformed frame (virtual camera).
    var cameraOutput: ((CVPixelBuffer) -> Void)?
    /// Receives every conformed frame while the preview is visible.
    var previewOutput: ((CVPixelBuffer) -> Void)?
    /// Main queue, about once per second.
    var onStats: ((StreamStats) -> Void)?

    private let framingLock = OSAllocatedUnfairLock(initialState: PortraitFraming.fill)
    var framing: PortraitFraming {
        get { framingLock.withLock { $0 } }
        set { framingLock.withLock { $0 = newValue } }
    }

    private let log = Logger(subsystem: "app.icam.mac", category: "pipeline")
    private let decoder = VideoDecoder()
    private let conformer = FrameConformer()
    private var codec: VideoCodec?
    private var sourceWidth = 0
    private var sourceHeight = 0

    private var windowStart = CACurrentMediaTime()
    private var framesInWindow = 0
    private var bytesInWindow = 0
    private var lastRTT: Double = 0

    func reset() {
        decoder.reset()
        codec = nil
        publishStats(force: true, idle: true)
    }

    func requireKeyFrame() {
        decoder.requireKeyFrame()
    }

    func handleFormat(_ packet: VideoFormatPacket) {
        codec = packet.codec
        decoder.setFormat(packet)
    }

    /// Returns false if the stream needs a key frame.
    func handleFrame(_ frame: VideoFramePacket) -> Bool {
        bytesInWindow += frame.data.count
        let result = decoder.decode(frame)
        defer { publishStats(force: false, idle: false) }
        switch result {
        case .decoded(let buffer):
            sourceWidth = CVPixelBufferGetWidth(buffer)
            sourceHeight = CVPixelBufferGetHeight(buffer)
            framesInWindow += 1
            if let conformed = conformer.conform(buffer, framing: framing) {
                cameraOutput?(conformed)
                previewOutput?(conformed)
            }
            return true
        case .needsKeyFrame:
            return false
        case .dropped:
            return true
        }
    }

    func updateRTT(_ seconds: Double) {
        lastRTT = seconds
    }

    private func publishStats(force: Bool, idle: Bool) {
        let now = CACurrentMediaTime()
        let elapsed = now - windowStart
        guard force || elapsed >= 1 else { return }
        let stats = idle ? StreamStats() : StreamStats(
            fps: Double(framesInWindow) / max(elapsed, 0.001),
            bitrate: Double(bytesInWindow * 8) / max(elapsed, 0.001),
            rttMs: lastRTT * 1000,
            width: sourceWidth, height: sourceHeight, codec: codec)
        windowStart = now
        framesInWindow = 0
        bytesInWindow = 0
        let callback = onStats
        DispatchQueue.main.async { callback?(stats) }
    }
}
