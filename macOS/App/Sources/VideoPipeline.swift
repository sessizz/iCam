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
    /// Delay the playout buffer currently adds to smooth out arrival jitter.
    var playoutDelayMs: Double = 0
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

/// Releases decoded frames at the iPhone's capture cadence.
///
/// Wi-Fi delivers frames in bursts (power saving, retransmissions, other
/// traffic); showing each frame the moment it arrives makes motion stutter
/// even when no frame is lost. Every frame is held until its capture time
/// plus an offset: the fastest recent transit plus the link's recent jitter
/// (97th percentile over 4 s, at most 100 ms, so even a delay that hits one
/// frame in 30 is absorbed). Over USB that is a
/// millisecond or two; frames that come later than that are shown at once.
///
/// The offset follows its target gradually (a few ms per frame) so that a
/// jump in the estimate never holds or skips a frame visibly.
final class PlayoutBuffer: @unchecked Sendable {
    /// Called on the buffer's own serial queue, in capture order.
    var output: ((CVPixelBuffer) -> Void)?

    static let window: CFTimeInterval = 4
    static let maxDelay: CFTimeInterval = 0.1
    /// Largest change of the applied offset per frame: growing is allowed
    /// faster (protects against the next burst) than shrinking.
    static let maxGrowthPerFrame: CFTimeInterval = 0.003
    static let maxShrinkPerFrame: CFTimeInterval = 0.001

    private let queue = DispatchQueue(label: "app.icam.playout", qos: .userInteractive)
    private let delayLock = OSAllocatedUnfairLock(initialState: 0.0)

    // Confined to `queue`.
    private var history: [(arrival: CFTimeInterval, transit: CFTimeInterval)] = []
    private var delay: CFTimeInterval = 0
    /// Capture time → due time offset in use (nil until the first frame).
    private var offset: CFTimeInterval?
    private var lastDue: CFTimeInterval = 0
    private var pending: [(due: CFTimeInterval, buffer: CVPixelBuffer)] = []
    private var timer: DispatchSourceTimer?

    /// The delay currently added, in seconds. Any queue.
    var currentDelay: CFTimeInterval { delayLock.withLock { $0 } }

    /// `captureTime` is on the iPhone's clock and `arrival` on this Mac's
    /// (CACurrentMediaTime); only differences between frames matter.
    func enqueue(_ buffer: CVPixelBuffer, captureTime: CFTimeInterval, arrival: CFTimeInterval) {
        queue.async { self.schedule(buffer, captureTime: captureTime, arrival: arrival) }
    }

    /// Forgets the link's timing (new stream or transport); frames still
    /// waiting are shown right away.
    func reset() {
        queue.async {
            self.history.removeAll()
            self.delay = 0
            self.offset = nil
            self.lastDue = 0
            self.delayLock.withLock { $0 = 0 }
            let waiting = self.pending
            self.pending.removeAll()
            for item in waiting { self.output?(item.buffer) }
            self.timer?.schedule(deadline: .distantFuture)
        }
    }

    private func schedule(_ buffer: CVPixelBuffer, captureTime: CFTimeInterval, arrival: CFTimeInterval) {
        let transit = arrival - captureTime
        history.append((arrival, transit))
        while let first = history.first, arrival - first.arrival > Self.window {
            history.removeFirst()
        }
        let transits = history.map(\.transit).sorted()
        let fastest = transits[0]
        let jitter = transits[min(transits.count - 1, transits.count * 97 / 100)] - fastest
        let wanted = min(Self.maxDelay, max(0, jitter))
        // The target delay grows at once (protect against the next burst)
        // and shrinks slowly so it doesn't oscillate; the offset actually
        // applied follows the target a few ms per frame at most.
        delay = wanted > delay ? wanted : delay * 0.98 + wanted * 0.02
        let target = fastest + delay
        let applied: CFTimeInterval
        if let offset {
            applied = min(max(target, offset - Self.maxShrinkPerFrame), offset + Self.maxGrowthPerFrame)
        } else {
            applied = target
        }
        offset = applied
        let addedDelay = max(0, applied - fastest)
        delayLock.withLock { $0 = addedDelay }

        // Never reorder, even when the estimate moves.
        let due = max(captureTime + applied, lastDue)
        lastDue = due
        if pending.isEmpty, due <= CACurrentMediaTime() + 0.001 {
            output?(buffer)
            return
        }
        pending.append((due, buffer))
        armTimer()
    }

    private func armTimer() {
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.setEventHandler { [weak self] in self?.fire() }
            timer.schedule(deadline: .distantFuture)
            timer.resume()
            self.timer = timer
        }
        guard let head = pending.first else {
            timer?.schedule(deadline: .distantFuture)
            return
        }
        let wait = max(0, head.due - CACurrentMediaTime())
        timer?.schedule(deadline: .now() + wait, leeway: .milliseconds(1))
    }

    private func fire() {
        let now = CACurrentMediaTime()
        while let head = pending.first, head.due <= now + 0.001 {
            pending.removeFirst()
            output?(head.buffer)
        }
        armTimer()
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
    private let playout = PlayoutBuffer()
    private var codec: VideoCodec?
    private var sourceWidth = 0
    private var sourceHeight = 0

    private var windowStart = CACurrentMediaTime()
    private var framesInWindow = 0
    private var bytesInWindow = 0
    private var lastRTT: Double = 0

    init() {
        playout.output = { [weak self] buffer in
            self?.cameraOutput?(buffer)
            self?.previewOutput?(buffer)
        }
    }

    func reset() {
        decoder.reset()
        playout.reset()
        codec = nil
        publishStats(force: true, idle: true)
    }

    /// Called when a (possibly different) connection starts feeding frames.
    func requireKeyFrame() {
        decoder.requireKeyFrame()
        playout.reset()
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
                playout.enqueue(conformed, captureTime: Double(frame.captureTimeMicros) / 1_000_000,
                                arrival: CACurrentMediaTime())
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
            playoutDelayMs: playout.currentDelay * 1000,
            width: sourceWidth, height: sourceHeight, codec: codec)
        windowStart = now
        framesInWindow = 0
        bytesInWindow = 0
        let callback = onStats
        DispatchQueue.main.async { callback?(stats) }
    }
}
