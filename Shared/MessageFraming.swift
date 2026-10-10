//
//  MessageFraming.swift
//  Shared between the iPhone app and the Mac app.
//

import Foundation

/// Builds framed messages.
enum MessageFramer {
    static let headerSize = 5

    static func frame(_ type: WireType, payload: Data) -> Data {
        var w = ByteWriter(capacity: headerSize + payload.count)
        w.write(type.rawValue)
        w.write(UInt32(payload.count))
        w.write(payload)
        return w.data
    }

    private static let encoder: JSONEncoder = JSONEncoder()

    static func frame(_ message: ControlMessage) -> Data {
        // Encoding our own value types cannot fail; fall back to an empty
        // payload rather than crashing if it ever does.
        let json = (try? encoder.encode(message)) ?? Data()
        return frame(.control, payload: json)
    }

    static func frameAck(sequence: UInt32) -> Data {
        var w = ByteWriter(capacity: headerSize + 4)
        w.write(WireType.frameAck.rawValue)
        w.write(UInt32(4))
        w.write(sequence)
        return w.data
    }
}

/// A decoded message coming off the wire.
enum InboundMessage {
    case control(ControlMessage)
    case videoFormat(VideoFormatPacket)
    case videoFrame(VideoFramePacket)
    case frameAck(UInt32)
}

/// Incremental parser for the framed byte stream. Feed it whatever the socket
/// returns; it hands back complete messages. Not thread safe – use it from a
/// single queue.
final class MessageParser {
    private var storage: [UInt8] = []
    private var readIndex = 0
    private let decoder = JSONDecoder()

    init() {
        storage.reserveCapacity(512 * 1024)
    }

    func append(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count > 0 else { return }
        compactIfNeeded(incoming: bytes.count)
        storage.append(contentsOf: bytes)
    }

    func append(_ data: Data) {
        data.withUnsafeBytes { append($0) }
    }

    func reset() {
        storage.removeAll(keepingCapacity: true)
        readIndex = 0
    }

    /// Returns the next complete message, `nil` if more bytes are needed.
    /// Throws on a corrupt stream – the connection must then be dropped.
    func next() throws -> InboundMessage? {
        while true {
            let available = storage.count - readIndex
            guard available >= MessageFramer.headerSize else { return nil }

            let typeRaw = storage[readIndex]
            let length = Int(storage[readIndex + 1]) << 24
                | Int(storage[readIndex + 2]) << 16
                | Int(storage[readIndex + 3]) << 8
                | Int(storage[readIndex + 4])
            guard length <= ICam.maxPayloadSize else { throw ProtocolError.payloadTooLarge(length) }
            guard available >= MessageFramer.headerSize + length else { return nil }

            let start = readIndex + MessageFramer.headerSize
            let payload = storage.withUnsafeBufferPointer { buffer in
                Data(bytes: buffer.baseAddress! + start, count: length)
            }
            readIndex = start + length

            guard let type = WireType(rawValue: typeRaw) else {
                // Unknown message from a newer peer: skip it.
                continue
            }
            switch type {
            case .control:
                return .control(try decoder.decode(ControlMessage.self, from: payload))
            case .videoFormat:
                return .videoFormat(try VideoFormatPacket(decoding: payload))
            case .videoFrame:
                return .videoFrame(try VideoFramePacket(decoding: payload))
            case .frameAck:
                var r = ByteReader(payload)
                return .frameAck(try r.read())
            }
        }
    }

    private func compactIfNeeded(incoming: Int) {
        guard readIndex > 0 else { return }
        if readIndex == storage.count {
            storage.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 256 * 1024 || storage.count + incoming > storage.capacity {
            storage.removeSubrange(0..<readIndex)
            readIndex = 0
        }
    }
}

// MARK: - Byte helpers (big endian)

struct ByteWriter {
    private(set) var data: Data

    init(capacity: Int = 64) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    mutating func write(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func write(_ bytes: UnsafeRawBufferPointer) {
        data.append(contentsOf: bytes)
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func read<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.endIndex else { throw ProtocolError.malformed("truncated") }
        var value: T = 0
        for i in 0..<size {
            value = (value << 8) | T(data[offset + i])
        }
        offset += size
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.endIndex else { throw ProtocolError.malformed("truncated") }
        let slice = data[offset..<(offset + count)]
        offset += count
        return Data(slice)
    }

    mutating func remainingData() -> Data {
        let slice = data[offset..<data.endIndex]
        offset = data.endIndex
        return Data(slice)
    }
}
