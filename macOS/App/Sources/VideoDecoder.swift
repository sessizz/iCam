//
//  VideoDecoder.swift
//  iCam (Mac)
//
//  Hardware H.264 / HEVC decoding to IOSurface-backed 420v buffers.
//

import CoreMedia
import VideoToolbox
import os

final class VideoDecoder {

    enum Result {
        case decoded(CVPixelBuffer)
        /// Frame skipped; the stream needs a key frame to resume.
        case needsKeyFrame
        case dropped
    }

    private let log = Logger(subsystem: "app.icam.mac", category: "decoder")
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentFormat: VideoFormatPacket?
    private var waitingForKeyFrame = true

    deinit { invalidate() }

    func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        waitingForKeyFrame = true
    }

    func reset() {
        invalidate()
        formatDescription = nil
        currentFormat = nil
    }

    // MARK: Format

    func setFormat(_ packet: VideoFormatPacket) {
        guard packet != currentFormat else { return }
        guard let description = Self.makeFormatDescription(packet) else {
            log.error("Could not build format description")
            return
        }
        currentFormat = packet
        formatDescription = description
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            return
        }
        invalidate()
        createSession(description)
    }

    private static func makeFormatDescription(_ packet: VideoFormatPacket) -> CMVideoFormatDescription? {
        // Copy the parameter sets into stable memory for the C API.
        let pointers = packet.parameterSets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let constPointers = pointers.map { UnsafePointer($0) }
        let sizes = packet.parameterSets.map(\.count)

        var description: CMFormatDescription?
        let status: OSStatus
        switch packet.codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: constPointers.count,
                parameterSetPointers: constPointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(packet.nalLengthSize), formatDescriptionOut: &description)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: constPointers.count,
                parameterSetPointers: constPointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(packet.nalLengthSize), extensions: nil,
                formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    private func createSession(_ description: CMVideoFormatDescription) {
        let destination: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: destination as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else {
            log.error("VTDecompressionSessionCreate failed: \(status)")
            return
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        waitingForKeyFrame = true
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        log.info("Decoder ready: \(dimensions.width)x\(dimensions.height)")
    }

    // MARK: Decode

    func decode(_ frame: VideoFramePacket) -> Result {
        guard let session, let formatDescription else { return .needsKeyFrame }
        if waitingForKeyFrame {
            guard frame.isKeyFrame else { return .needsKeyFrame }
            waitingForKeyFrame = false
        }
        guard let sampleBuffer = makeSampleBuffer(frame.data, format: formatDescription) else { return .dropped }

        var output: CVPixelBuffer?
        var callbackStatus: OSStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            callbackStatus = status
            output = imageBuffer
        }

        if status != noErr || callbackStatus != noErr {
            let failure = status != noErr ? status : callbackStatus
            log.error("Decode failed: \(failure)")
            if failure == kVTInvalidSessionErr {
                invalidate()
                createSession(formatDescription)
            }
            waitingForKeyFrame = true
            return .needsKeyFrame
        }
        guard let output else { return .dropped }
        return .decoded(output)
    }

    private func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let length = data.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer else { return nil }
        let copyStatus = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }
}
