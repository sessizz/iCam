//
//  ICamProtocol.swift
//  Shared between the iPhone app and the Mac app.
//
//  Wire format
//  -----------
//  Every message on the TCP stream (USB tunnel or Wi-Fi) is framed as:
//
//      +--------+----------------------+-----------------+
//      | type   | payload length (BE)  | payload         |
//      | UInt8  | UInt32               | <length> bytes  |
//      +--------+----------------------+-----------------+
//
//  * `control`     – JSON encoded `ControlMessage` (rare, small).
//  * `videoFormat` – codec parameter sets (SPS/PPS[/VPS]); sent before the
//                    first key frame and whenever the parameters change.
//  * `videoFrame`  – one encoded access unit in AVCC/HVCC (length prefixed
//                    NAL units) layout, exactly as VideoToolbox produces it.
//  * `frameAck`    – Mac → iPhone acknowledgement of a decoded frame. Used
//                    for end-to-end congestion control.
//

import Foundation

enum ICam {
    /// Bump when the wire format changes incompatibly.
    static let protocolVersion = 1

    /// TCP port the iPhone listens on. The USB (usbmux) tunnel connects to
    /// this port on the device; Wi-Fi peers discover it through Bonjour.
    static let tcpPort: UInt16 = 47820

    static let bonjourServiceType = "_icam._tcp"

    /// Hard upper bound for a single framed message. A 1080p key frame at
    /// high bitrate is a few hundred KB, so this is very generous.
    static let maxPayloadSize = 16 * 1024 * 1024

    /// The format exposed by the virtual camera on the Mac.
    static let outputWidth = 1920
    static let outputHeight = 1080
    static let frameRate = 30

    /// Seconds without any inbound traffic after which a peer is considered
    /// gone. Both sides send at least one message per second.
    static let livenessTimeout: TimeInterval = 4.0
    static let heartbeatInterval: TimeInterval = 1.0
}

// MARK: - Message kinds

enum WireType: UInt8 {
    case control = 1
    case videoFormat = 2
    case videoFrame = 3
    case frameAck = 4
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

enum TransportKind: String, Codable {
    case usb
    case wifi

    var displayName: String {
        switch self {
        case .usb: return "USB"
        case .wifi: return "Wi-Fi"
        }
    }
}

// MARK: - Control messages (JSON)

/// Mac → iPhone, first message on every connection.
struct HelloMessage: Codable {
    var protocolVersion: Int
    /// Stable identifier of the Mac, used to let a Mac replace its own
    /// stale/older connection (e.g. Wi-Fi → USB hand-over) while rejecting
    /// other Macs while one is connected.
    var hostID: String
    var hostName: String
    var transport: TransportKind
}

/// iPhone → Mac, answer to `HelloMessage`.
struct HelloReply: Codable {
    var protocolVersion: Int
    var accepted: Bool
    var reason: String?
    var deviceID: String
    var deviceName: String
    var deviceModel: String
}

/// Mac → iPhone: start capturing and streaming with these parameters.
struct StreamConfig: Codable, Equatable {
    var width: Int
    var height: Int
    var fps: Int
    var codec: VideoCodec
    /// Initial target bitrate in bits per second.
    var bitrate: Int
    /// Ceiling for the adaptive bitrate controller.
    var maxBitrate: Int
}

/// Mac → iPhone camera controls. Every field is optional so the Mac can send
/// partial updates.
struct CameraSettings: Codable, Equatable {
    var lensID: String?
    var zoom: Double?
    var mirrored: Bool?
    var stabilization: Bool?
}

struct LensInfo: Codable, Hashable, Identifiable {
    var id: String
    /// Human readable, e.g. "Ultra Wide".
    var name: String
    /// Short zoom-style label, e.g. "0.5×", "1×", "3×", "Front".
    var label: String
    var maxZoom: Double
}

/// iPhone → Mac: everything the Mac UI needs to mirror the phone's state.
struct PhoneStatus: Codable, Equatable {
    var lenses: [LensInfo]
    var currentLensID: String?
    var zoom: Double
    var mirrored: Bool
    var stabilization: Bool
    var isCapturing: Bool
    var isPortrait: Bool
    var interruption: String?
    var batteryLevel: Float
    var isCharging: Bool
    /// `ProcessInfo.ThermalState.rawValue`
    var thermalState: Int
    var bitrate: Int
    /// Link health seen by the iPhone's congestion control (optional so
    /// older builds on either side still understand each other): median
    /// frame round trip and queueing delay in the last second, and camera
    /// frames dropped before encoding since the previous status.
    var roundTripMs: Int? = nil
    var queueDelayMs: Int? = nil
    var droppedFrames: Int? = nil
}

struct PingMessage: Codable {
    /// Sender's monotonic clock in seconds; echoed back unchanged.
    var t: Double
}

enum ControlMessage: Codable {
    case hello(HelloMessage)
    case helloReply(HelloReply)
    case startStream(StreamConfig)
    case stopStream
    case requestKeyFrame
    case updateSettings(CameraSettings)
    case status(PhoneStatus)
    case ping(PingMessage)
    case pong(PingMessage)
}

// MARK: - Binary video messages

struct VideoFormatPacket: Equatable {
    var codec: VideoCodec
    var width: Int
    var height: Int
    var nalLengthSize: Int
    /// SPS + PPS for H.264, VPS + SPS + PPS for HEVC.
    var parameterSets: [Data]

    func encoded() -> Data {
        var w = ByteWriter()
        w.write(UInt8(codec == .h264 ? 0 : 1))
        w.write(UInt16(clamping: width))
        w.write(UInt16(clamping: height))
        w.write(UInt8(clamping: nalLengthSize))
        w.write(UInt8(clamping: parameterSets.count))
        for set in parameterSets {
            w.write(UInt16(clamping: set.count))
            w.write(set)
        }
        return w.data
    }

    init(codec: VideoCodec, width: Int, height: Int, nalLengthSize: Int, parameterSets: [Data]) {
        self.codec = codec
        self.width = width
        self.height = height
        self.nalLengthSize = nalLengthSize
        self.parameterSets = parameterSets
    }

    init(decoding data: Data) throws {
        var r = ByteReader(data)
        let codecRaw: UInt8 = try r.read()
        guard codecRaw <= 1 else { throw ProtocolError.malformed("codec \(codecRaw)") }
        codec = codecRaw == 0 ? .h264 : .hevc
        width = Int(try r.read() as UInt16)
        height = Int(try r.read() as UInt16)
        nalLengthSize = Int(try r.read() as UInt8)
        let count = Int(try r.read() as UInt8)
        var sets: [Data] = []
        sets.reserveCapacity(count)
        for _ in 0..<count {
            let length = Int(try r.read() as UInt16)
            sets.append(try r.readData(count: length))
        }
        parameterSets = sets
        guard !sets.isEmpty, [1, 2, 4].contains(nalLengthSize) else {
            throw ProtocolError.malformed("parameter sets")
        }
    }
}

struct VideoFramePacket {
    static let headerSize = 4 + 1 + 8

    var sequence: UInt32
    var isKeyFrame: Bool
    /// Capture time on the iPhone's clock, microseconds.
    var captureTimeMicros: Int64
    /// AVCC / HVCC sample data (length prefixed NAL units).
    var data: Data

    /// Builds the complete framed message (wire header + packet header +
    /// sample data) with a single allocation.
    static func framedMessage(sequence: UInt32, isKeyFrame: Bool, captureTimeMicros: Int64,
                              sampleBytes: UnsafeRawBufferPointer) -> Data {
        var w = ByteWriter(capacity: MessageFramer.headerSize + headerSize + sampleBytes.count)
        w.write(WireType.videoFrame.rawValue)
        w.write(UInt32(headerSize + sampleBytes.count))
        w.write(sequence)
        w.write(UInt8(isKeyFrame ? 1 : 0))
        w.write(captureTimeMicros)
        w.write(sampleBytes)
        return w.data
    }

    init(decoding payload: Data) throws {
        var r = ByteReader(payload)
        sequence = try r.read()
        let flags: UInt8 = try r.read()
        isKeyFrame = flags & 1 != 0
        captureTimeMicros = try r.read()
        data = r.remainingData()
        guard !data.isEmpty else { throw ProtocolError.malformed("empty frame") }
    }
}

enum ProtocolError: Error, CustomStringConvertible {
    case malformed(String)
    case payloadTooLarge(Int)
    case versionMismatch(Int)

    var description: String {
        switch self {
        case .malformed(let what): return "Malformed message (\(what))"
        case .payloadTooLarge(let size): return "Payload too large (\(size) bytes)"
        case .versionMismatch(let v): return "Incompatible protocol version \(v)"
        }
    }
}
