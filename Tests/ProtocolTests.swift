//
//  ProtocolTests.swift
//
//  Self-contained tests for the wire protocol shared by both apps.
//  Run:  swiftc -parse-as-library Shared/ICamProtocol.swift Shared/MessageFraming.swift \
//          Tests/ProtocolTests.swift -o protocol-tests && ./protocol-tests
//

import Foundation

@main
enum ProtocolTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                       line: Int = #line) {
        if !condition() {
            failures += 1
            print("FAIL (line \(line)): \(message)")
        }
    }

    static func main() throws {
        try controlRoundTrip()
        try chunkedParsing()
        try videoPackets()
        try unknownTypesAreSkipped()
        oversizedPayloadThrows()
        if failures == 0 {
            print("All protocol tests passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }

    static func parseAll(_ data: Data) throws -> [InboundMessage] {
        let parser = MessageParser()
        parser.append(data)
        var messages: [InboundMessage] = []
        while let message = try parser.next() { messages.append(message) }
        return messages
    }

    static func controlRoundTrip() throws {
        let hello = HelloMessage(protocolVersion: ICam.protocolVersion, hostID: "host", hostName: "Mac",
                                 transport: .usb)
        let status = PhoneStatus(
            lenses: [LensInfo(id: "back-wide", name: "Wide", label: "1×", maxZoom: 5)],
            currentLensID: "back-wide", zoom: 1.5, mirrored: true, stabilization: false, isCapturing: true,
            isPortrait: false, interruption: nil, batteryLevel: 0.5, isCharging: true, thermalState: 1,
            bitrate: 12_000_000)
        var data = MessageFramer.frame(.hello(hello))
        data += MessageFramer.frame(.status(status))
        data += MessageFramer.frame(.stopStream)
        data += MessageFramer.frame(.updateSettings(CameraSettings(zoom: 2)))

        let messages = try parseAll(data)
        expect(messages.count == 4, "four messages")
        if case .control(.hello(let decoded)) = messages[0] {
            expect(decoded.hostID == "host" && decoded.transport == .usb, "hello fields")
        } else { expect(false, "hello type") }
        if case .control(.status(let decoded)) = messages[1] {
            expect(decoded == status, "status equality")
        } else { expect(false, "status type") }
        if case .control(.stopStream) = messages[2] {} else { expect(false, "stopStream") }
        if case .control(.updateSettings(let settings)) = messages[3] {
            expect(settings.zoom == 2 && settings.lensID == nil, "partial settings")
        } else { expect(false, "settings type") }
    }

    static func chunkedParsing() throws {
        var data = Data()
        for i in 0..<50 {
            data += MessageFramer.frame(.ping(PingMessage(t: Double(i))))
            data += MessageFramer.frameAck(sequence: UInt32(i))
        }
        let parser = MessageParser()
        var pings = 0
        var acks: [UInt32] = []
        // Feed in awkward chunk sizes, including single bytes.
        var offset = 0
        var chunk = 1
        while offset < data.count {
            let end = min(data.count, offset + chunk)
            parser.append(data.subdata(in: offset..<end))
            offset = end
            chunk = chunk % 7 + 1
            while let message = try parser.next() {
                switch message {
                case .control(.ping(let ping)):
                    expect(ping.t == Double(pings), "ping order")
                    pings += 1
                case .frameAck(let seq):
                    acks.append(seq)
                default:
                    expect(false, "unexpected message")
                }
            }
        }
        expect(pings == 50, "all pings parsed (\(pings))")
        expect(acks == (0..<50).map(UInt32.init), "acks in order")
    }

    static func videoPackets() throws {
        let format = VideoFormatPacket(codec: .hevc, width: 1920, height: 1080, nalLengthSize: 4,
                                       parameterSets: [Data([0x40, 1, 2]), Data([0x42, 3]), Data([0x44, 4, 5, 6])])
        let sample: [UInt8] = (0..<5000).map { UInt8($0 % 251) }
        var data = MessageFramer.frame(.videoFormat, payload: format.encoded())
        data += sample.withUnsafeBytes {
            VideoFramePacket.framedMessage(sequence: 0xFFFF_FFFE, isKeyFrame: true,
                                           captureTimeMicros: -123_456_789, sampleBytes: $0)
        }
        let messages = try parseAll(data)
        expect(messages.count == 2, "two video messages")
        if case .videoFormat(let decoded) = messages[0] {
            expect(decoded == format, "format round trip")
        } else { expect(false, "format type") }
        if case .videoFrame(let frame) = messages[1] {
            expect(frame.sequence == 0xFFFF_FFFE, "sequence")
            expect(frame.isKeyFrame, "key frame flag")
            expect(frame.captureTimeMicros == -123_456_789, "signed timestamp")
            expect(frame.data == Data(sample), "sample bytes")
        } else { expect(false, "frame type") }
    }

    static func unknownTypesAreSkipped() throws {
        var data = Data([0xEE, 0, 0, 0, 3, 1, 2, 3])
        data += MessageFramer.frameAck(sequence: 7)
        let messages = try parseAll(data)
        expect(messages.count == 1, "unknown message skipped")
        if case .frameAck(let seq) = messages.first { expect(seq == 7, "ack after unknown") }
    }

    static func oversizedPayloadThrows() {
        let parser = MessageParser()
        parser.append(Data([WireType.videoFrame.rawValue, 0x7F, 0xFF, 0xFF, 0xFF]))
        do {
            _ = try parser.next()
            expect(false, "oversized payload must throw")
        } catch {}
    }
}
