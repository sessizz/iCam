//
//  PipelineTests.swift
//
//  End-to-end test of the video path using the real app code on macOS:
//
//    synthetic camera frames → VideoEncoder (iPhone) → framed wire bytes
//      → MessageParser → VideoDecoder (Mac) → FrameConformer (1920×1080)
//
//  plus the Mac's playout buffer, which must turn bursty Wi-Fi arrival back
//  into an even frame pace.
//
//  Run (macOS):
//    swiftc -parse-as-library Shared/*.swift macOS/Shared/*.swift \
//      iOS/Sources/VideoEncoder.swift macOS/App/Sources/VideoDecoder.swift \
//      macOS/App/Sources/VideoPipeline.swift macOS/CameraExtension/Sources/PlaceholderRenderer.swift \
//      Tests/PipelineTests.swift -o /tmp/pipeline-tests
//    /tmp/pipeline-tests
//

import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

@main
enum PipelineTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        if !condition() {
            failures += 1
            print("FAIL (line \(line)): \(message)")
        }
    }

    static func main() {
        placeholder()
        playout()
        expect(VirtualCamera.fourCharCode("iCdm") == 0x6943_646D, "four char code")
        expect(VirtualCamera.extensionPropertyName("iCdm") == "4cc_iCdm_glob_0000", "property name")
        for codec in VideoCodec.allCases {
            run(codec: codec, width: 1920, height: 1080, frames: 90)
            run(codec: codec, width: 1080, height: 1920, frames: 30) // iPhone held in portrait
        }
        if failures == 0 {
            print("All pipeline tests passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }

    // MARK: Placeholder

    static func placeholder() {
        let renderer = PlaceholderRenderer()
        for (width, height) in [(1920, 1080), (1280, 720)] {
            guard let buffer = renderer.render(message: "Open iCam on your iPhone — çok uzun bir mesaj " +
                                                        String(repeating: "x", count: 200),
                                               width: width, height: height) else {
                expect(false, "placeholder \(width)x\(height) rendered")
                continue
            }
            expect(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height,
                   "placeholder size")
            expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                   "placeholder pixel format")
            // The text/glyph area must contain bright pixels on the dark background.
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            var bright = 0
            var maxValue: UInt8 = 0
            for y in stride(from: height / 4, to: height * 3 / 4, by: 2) {
                for x in stride(from: width / 4, to: width * 3 / 4, by: 2) {
                    let value = luma[y * rowBytes + x]
                    maxValue = max(maxValue, value)
                    if value > 120 { bright += 1 }
                }
            }
            let corner = luma[4 * rowBytes + 4]
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            expect(bright > 200, "placeholder has visible content (\(bright) bright samples, max \(maxValue))")
            expect(corner < 60, "placeholder background is dark (\(corner))")
            print("placeholder \(width)x\(height): \(bright) bright samples, background luma \(corner)")
        }
    }

    // MARK: Playout buffer

    /// Every 10th frame stalls for 70 ms and the frames queued behind it
    /// arrive together (TCP head-of-line blocking over Wi-Fi). Once the
    /// buffer has seen a stall, frames must leave at an even pace again.
    ///
    /// Arrival times are passed in rather than produced by sleeping, so CI
    /// machines with coarse timers test the scheduling, not their sleep().
    static func playout() {
        let buffer = PlayoutBuffer()
        let total = 90
        let lock = NSLock()
        var outputs: [CFTimeInterval] = []
        let done = DispatchSemaphore(value: 0)
        buffer.output = { _ in
            lock.lock()
            outputs.append(CACurrentMediaTime())
            let count = outputs.count
            lock.unlock()
            if count == total { done.signal() }
        }
        let pixel = makeFrame(width: 64, height: 64, index: 0)
        let start = CACurrentMediaTime() + 0.2
        let phoneClockOffset = 12_345.0 // the iPhone's clock differs from the Mac's
        var previousArrival = 0.0
        var arrivals: [CFTimeInterval] = []
        for index in 0..<total {
            let capture = Double(index) / 30
            let nominal = start + capture + 0.02 + (index % 10 == 0 ? 0.07 : 0)
            let arrival = max(nominal, previousArrival)
            previousArrival = arrival
            arrivals.append(arrival)
            buffer.enqueue(pixel, captureTime: capture + phoneClockOffset, arrival: arrival)
        }
        guard done.wait(timeout: .now() + 6) == .success else {
            expect(false, "playout: \(outputs.count)/\(total) frames came out")
            return
        }
        func maxGap(_ times: [CFTimeInterval]) -> Double {
            zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0
        }
        let inputGap = maxGap(Array(arrivals[15...]))
        let outputGap = maxGap(Array(outputs[15...]))
        let pace = (outputs[total - 1] - outputs[15]) / Double(total - 1 - 15)
        print(String(format: "playout: largest gap %.0f ms in, %.0f ms out; %.1f ms per frame; delay %.0f ms",
                     inputGap * 1000, outputGap * 1000, pace * 1000, buffer.currentDelay * 1000))
        expect(inputGap > 0.09, "playout: the test produces stalls")
        expect(outputGap < 0.055, "playout: even pace after stalls (largest gap \(Int(outputGap * 1000)) ms)")
        expect(abs(pace - 1.0 / 30) < 0.004, "playout: 30 fps pace")
        expect(buffer.currentDelay <= PlayoutBuffer.maxDelay + 0.001, "playout: delay is capped")
    }

    // MARK: Synthetic frames

    static func makeFrame(width: Int, height: Int, index: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attributes as CFDictionary, &buffer)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        // Moving diagonal gradient on luma, constant-ish chroma.
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for y in 0..<height {
            let row = luma + y * lumaStride
            for x in 0..<width {
                row[x] = UInt8(16 + ((x + y + index * 8) & 0xFF) * 219 / 255)
            }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for y in 0..<(height / 2) {
            let row = chroma + y * chromaStride
            for x in 0..<(width / 2) {
                row[2 * x] = UInt8(128 + (x % 32))
                row[2 * x + 1] = UInt8(128 - (y % 32))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    // MARK: Test

    /// CI machines are VMs; skip a codec only if the system has no encoder
    /// for it at all (not a bug in our code).
    static func encoderAvailable(_ codec: VideoCodec, width: Int, height: Int) -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr
    }

    static func run(codec: VideoCodec, width: Int, height: Int, frames: Int) {
        let label = "\(codec.rawValue) \(width)x\(height)"
        guard encoderAvailable(codec, width: width, height: height) else {
            print("SKIP \(label): no encoder on this machine")
            return
        }
        let encoder = VideoEncoder()
        encoder.configure(codec: codec, bitrate: 12_000_000)

        let lock = NSLock()
        var wire = Data()
        var encodedFrames: [(sequence: UInt32, keyFrame: Bool)] = []
        var formatCount = 0
        var encodeTimes: [CFTimeInterval] = []
        var submitTimes: [CFTimeInterval] = []
        let done = DispatchSemaphore(value: 0)

        encoder.onEncodedFrame = { frame in
            lock.lock()
            if let format = frame.format {
                wire += MessageFramer.frame(.videoFormat, payload: format.encoded())
                formatCount += 1
            }
            wire += frame.message
            encodedFrames.append((frame.sequence, frame.isKeyFrame))
            let index = encodedFrames.count - 1
            if index < submitTimes.count { encodeTimes.append(CACurrentMediaTime() - submitTimes[index]) }
            let finished = encodedFrames.count == frames
            lock.unlock()
            if finished { done.signal() }
        }

        for index in 0..<frames {
            let pixelBuffer = makeFrame(width: width, height: height, index: index)
            if index == frames / 2 { encoder.requestKeyFrame() }
            lock.lock()
            submitTimes.append(CACurrentMediaTime())
            lock.unlock()
            encoder.encode(pixelBuffer, presentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
            usleep(33_000) // camera pace
        }
        let timedOut = done.wait(timeout: .now() + 20) == .timedOut
        encoder.invalidate()
        expect(!timedOut, "\(label): encoder produced \(encodedFrames.count)/\(frames) frames")
        guard !encodedFrames.isEmpty else { return }

        expect(encodedFrames.first?.keyFrame == true, "\(label): first frame is a key frame")
        expect(encodedFrames.filter(\.keyFrame).count >= 2, "\(label): requested key frame honoured")
        expect(formatCount >= 1, "\(label): parameter sets sent")
        let sequences = encodedFrames.map(\.sequence)
        expect(zip(sequences, sequences.dropFirst()).allSatisfy { $1 == $0 &+ 1 }, "\(label): sequential numbering")

        // Decode on the "Mac".
        let parser = MessageParser()
        let decoder = VideoDecoder()
        let conformer = FrameConformer()
        var decoded = 0
        var decodeTime: CFTimeInterval = 0
        var conformedOK = true
        // Deliver in odd-sized chunks like a real socket.
        var offset = 0
        while offset < wire.count {
            let end = min(wire.count, offset + 1_337 + (offset % 4096))
            parser.append(wire.subdata(in: offset..<end))
            offset = end
            do {
                while let message = try parser.next() {
                    switch message {
                    case .videoFormat(let format):
                        expect(format.codec == codec, "\(label): codec in format packet")
                        expect(format.width == width && format.height == height, "\(label): format dimensions")
                        decoder.setFormat(format)
                    case .videoFrame(let frame):
                        let start = CACurrentMediaTime()
                        let result = decoder.decode(frame)
                        decodeTime += CACurrentMediaTime() - start
                        if case .decoded(let buffer) = result {
                            decoded += 1
                            expect(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height,
                                   "\(label): decoded dimensions")
                            for framing in PortraitFraming.allCases {
                                guard let out = conformer.conform(buffer, framing: framing),
                                      CVPixelBufferGetWidth(out) == VirtualCamera.width,
                                      CVPixelBufferGetHeight(out) == VirtualCamera.height,
                                      CVPixelBufferGetPixelFormatType(out)
                                          == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
                                    conformedOK = false
                                    continue
                                }
                            }
                        } else {
                            expect(false, "\(label): frame \(frame.sequence) not decoded (\(result))")
                        }
                    default:
                        break
                    }
                }
            } catch {
                expect(false, "\(label): parser error \(error)")
                return
            }
        }
        expect(decoded == encodedFrames.count, "\(label): decoded \(decoded)/\(encodedFrames.count)")
        expect(conformedOK, "\(label): conformed to 1920×1080 420v")

        let averageEncode = encodeTimes.isEmpty ? 0 : encodeTimes.reduce(0, +) / Double(encodeTimes.count)
        let kbps = Double(wire.count * 8) / (Double(frames) / 30) / 1000
        print(String(format: "%@: %d frames, %.0f kbps, encode %.1f ms (incl. queueing), decode %.2f ms/frame",
                     label, decoded, kbps, averageEncode * 1000, decodeTime / Double(max(decoded, 1)) * 1000))
    }
}
