//
//  VideoEncoder.swift
//  iCam (iPhone)
//
//  Hardware H.264 / HEVC encoder tuned for real-time, low latency streaming:
//  no B-frames, low-latency rate control, one frame in → one frame out.
//

import CoreMedia
import VideoToolbox
import os

struct EncodedFrame {
    /// Non-nil when the codec parameters changed (always set for the first
    /// frame of a session). Must be sent before `message`.
    var format: VideoFormatPacket?
    /// The complete framed `videoFrame` message, ready to write to the wire.
    var message: Data
    var sequence: UInt32
    var isKeyFrame: Bool
}

final class VideoEncoder {
    /// Called on a VideoToolbox thread, in encode order.
    var onEncodedFrame: ((EncodedFrame) -> Void)?

    private let log = Logger(subsystem: "app.icam", category: "encoder")
    private var session: VTCompressionSession?
    private var sessionWidth: Int32 = 0
    private var sessionHeight: Int32 = 0
    private var codec: VideoCodec = .h264
    private var bitrate: Int = 10_000_000
    private var forceKeyFrame = true

    /// Touched only from the VideoToolbox output thread.
    private var lastFormat: VideoFormatPacket?
    private var sequence: UInt32 = 0

    private let frameDuration = CMTime(value: 1, timescale: CMTimeScale(ICam.frameRate))

    deinit { invalidate() }

    /// Must be called before the first `encode` and whenever the stream is
    /// (re)started.
    func configure(codec: VideoCodec, bitrate: Int) {
        invalidate()
        self.codec = codec
        self.bitrate = bitrate
        lastFormat = nil
        forceKeyFrame = true
    }

    func requestKeyFrame() {
        forceKeyFrame = true
    }

    func setBitrate(_ newValue: Int) {
        bitrate = newValue
        guard let session else { return }
        applyBitrate(to: session)
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        sessionWidth = 0
        sessionHeight = 0
    }

    /// Encodes one frame. Call from a single serial queue.
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if session == nil || width != sessionWidth || height != sessionHeight {
            invalidate()
            guard createSession(width: width, height: height) else { return }
            forceKeyFrame = true
        }
        guard let session else { return }

        var properties: CFDictionary?
        if forceKeyFrame {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKeyFrame = false
        }

        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: frameDuration, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sampleBuffer else {
                if status != noErr { self.log.error("Encode callback error \(status)") }
                return
            }
            self.handleEncoded(sampleBuffer)
        }

        if status != noErr {
            log.error("VTCompressionSessionEncodeFrame failed: \(status)")
            // The hardware encoder may have been reclaimed (e.g. app went to
            // background). Rebuild on the next frame.
            invalidate()
        }
    }

    // MARK: Session

    private func createSession(width: Int32, height: Int32) -> Bool {
        let codecType: CMVideoCodecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let sourceAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var created: VTCompressionSession?
        var lowLatency = false
        // Low-latency rate control first; fall back to a plain hardware
        // encoder if this codec/OS combination doesn't support it.
        let specifications: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true],
            [:]
        ]
        for specification in specifications {
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: width, height: height, codecType: codecType,
                encoderSpecification: specification.isEmpty ? nil : specification as CFDictionary,
                imageBufferAttributes: sourceAttributes as CFDictionary,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &created)
            if status == noErr, created != nil {
                lowLatency = !specification.isEmpty
                break
            }
            log.notice("VTCompressionSessionCreate failed (\(status)) with spec \(specification.count)")
            created = nil
        }
        guard let session = created else {
            log.error("Unable to create compression session")
            return false
        }

        func set(_ key: CFString, _ value: CFTypeRef) {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr {
                log.debug("VTSessionSetProperty \(key as String) failed: \(status)")
            }
        }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: ICam.frameRate))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: ICam.frameRate * 4))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 4))
        if codec == .hevc {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            // Low-latency mode supports the constrained profiles (no B-frames,
            // which we don't use anyway).
            set(kVTCompressionPropertyKey_ProfileLevel,
                lowLatency ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
            set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        }
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        applyBitrate(to: session)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        sessionWidth = width
        sessionHeight = height
        log.info("Encoder ready: \(self.codec.rawValue, privacy: .public) \(width)x\(height) @ \(self.bitrate) bps, low latency: \(lowLatency)")
        return true
    }

    private func applyBitrate(to session: VTCompressionSession) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        // Cap short-term peaks at 1.5× the average over one second so a
        // burst of motion can't flood the link.
        let bytesPerSecond = Double(bitrate) * 1.5 / 8
        let limits = [NSNumber(value: bytesPerSecond), NSNumber(value: 1.0)] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    // MARK: Output

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyFrame = !notSync

        var format: VideoFormatPacket?
        if isKeyFrame || lastFormat == nil,
           let description = CMSampleBufferGetFormatDescription(sampleBuffer),
           let packet = Self.formatPacket(from: description) {
            if packet != lastFormat {
                format = packet
                lastFormat = packet
            }
        }
        guard lastFormat != nil else {
            log.error("Missing codec parameter sets; dropping frame")
            return
        }

        sequence &+= 1
        let seq = sequence
        let timeMicros = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000)

        let message: Data
        let length = CMBlockBufferGetDataLength(dataBuffer)
        var pointer: UnsafeMutablePointer<CChar>?
        var contiguousLength = 0
        if CMBlockBufferIsRangeContiguous(dataBuffer, atOffset: 0, length: length),
           CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                       totalLengthOut: &contiguousLength, dataPointerOut: &pointer) == noErr,
           let pointer {
            message = VideoFramePacket.framedMessage(
                sequence: seq, isKeyFrame: isKeyFrame, captureTimeMicros: timeMicros,
                sampleBytes: UnsafeRawBufferPointer(start: pointer, count: length))
        } else {
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length,
                                           destination: raw.baseAddress!)
            }
            guard status == noErr else { return }
            message = bytes.withUnsafeBytes { raw in
                VideoFramePacket.framedMessage(sequence: seq, isKeyFrame: isKeyFrame,
                                               captureTimeMicros: timeMicros, sampleBytes: raw)
            }
        }

        onEncodedFrame?(EncodedFrame(format: format, message: message, sequence: seq, isKeyFrame: isKeyFrame))
    }

    static func formatPacket(from description: CMFormatDescription) -> VideoFormatPacket? {
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        var count = 0
        var nalLength: Int32 = 0
        let isHEVC = CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC

        func parameterSet(at index: Int, pointer: inout UnsafePointer<UInt8>?, size: inout Int,
                          count: UnsafeMutablePointer<Int>?, nal: UnsafeMutablePointer<Int32>?) -> OSStatus {
            if isHEVC {
                return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: count, nalUnitHeaderLengthOut: nal)
            } else {
                return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: count, nalUnitHeaderLengthOut: nal)
            }
        }

        var firstPointer: UnsafePointer<UInt8>?
        var firstSize = 0
        guard parameterSet(at: 0, pointer: &firstPointer, size: &firstSize,
                           count: &count, nal: &nalLength) == noErr, count > 0 else { return nil }

        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard parameterSet(at: index, pointer: &pointer, size: &size, count: nil, nal: nil) == noErr,
                  let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return VideoFormatPacket(codec: isHEVC ? .hevc : .h264,
                                 width: Int(dimensions.width), height: Int(dimensions.height),
                                 nalLengthSize: Int(nalLength), parameterSets: sets)
    }
}
