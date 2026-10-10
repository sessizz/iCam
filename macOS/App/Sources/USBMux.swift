//
//  USBMux.swift
//  iCam (Mac)
//
//  Minimal usbmuxd client. usbmuxd is the system daemon Finder and Xcode use
//  to talk to iOS devices over USB. It can tunnel a TCP connection to a port
//  on the device, which gives us a fast, reliable, low-latency wired link
//  with no network configuration at all.
//
//  Protocol: 16-byte little-endian header (length, version = 1,
//  message = 8 "plist", tag) followed by an XML property list.
//

import Darwin
import Foundation
import os

struct USBDevice: Hashable {
    let muxID: Int
    let serialNumber: String
}

enum USBMuxError: Error, CustomStringConvertible {
    case socket(String)
    case protocolError(String)
    case connectRefused(Int)

    var description: String {
        switch self {
        case .socket(let message): return "usbmuxd socket error: \(message)"
        case .protocolError(let message): return "usbmuxd protocol error: \(message)"
        case .connectRefused(let code): return "usbmuxd refused connection (\(code))"
        }
    }
}

enum USBMux {
    static let socketPath = "/var/run/usbmuxd"
    private static let headerSize = 16

    /// Opens a connected, blocking unix socket to usbmuxd.
    static func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw USBMuxError.socket(String(cString: strerror(errno))) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes.prefix(raw.count - 1))
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw USBMuxError.socket(message)
        }
        return fd
    }

    static func encode(_ plist: [String: Any], tag: UInt32) throws -> Data {
        let body = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var header = Data(capacity: headerSize)
        for value in [UInt32(headerSize + body.count), 1, 8, tag] {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        return header + body
    }

    static func baseRequest(_ type: String) -> [String: Any] {
        [
            "MessageType": type,
            "ClientVersionString": "iCam",
            "ProgName": "iCam",
            "kLibUSBMuxVersion": 3
        ]
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw USBMuxError.socket(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }

    static func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < count {
                let n = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                if n == 0 { throw USBMuxError.socket("connection closed") }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw USBMuxError.socket(String(cString: strerror(errno)))
                }
                offset += n
            }
        }
        return data
    }

    /// Reads one framed plist message (blocking).
    static func readMessage(_ fd: Int32) throws -> [String: Any] {
        let header = try readExactly(fd, count: headerSize)
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length >= headerSize, length < 1 << 20 else {
            throw USBMuxError.protocolError("bad length \(length)")
        }
        let body = try readExactly(fd, count: length - headerSize)
        guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw USBMuxError.protocolError("not a dictionary")
        }
        return plist
    }

    /// Opens a tunnel to `port` on the device. Blocking; call off the main
    /// thread. On success the returned socket is a raw byte stream to the
    /// iPhone app.
    static func connect(to device: USBDevice, port: UInt16) throws -> Int32 {
        let fd = try openSocket()
        do {
            var request = baseRequest("Connect")
            request["DeviceID"] = device.muxID
            request["PortNumber"] = Int(port.bigEndian) // network byte order
            try writeAll(fd, try encode(request, tag: 1))
            let reply = try readMessage(fd)
            let code = (reply["Number"] as? Int) ?? -1
            guard code == 0 else { throw USBMuxError.connectRefused(code) }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }
}

/// Keeps a "Listen" connection to usbmuxd open and reports USB-attached iOS
/// devices as they come and go.
final class USBDeviceMonitor {
    /// Main queue.
    var onChange: (([USBDevice]) -> Void)?

    private let log = Logger(subsystem: "app.icam.mac", category: "usbmux")
    private let queue = DispatchQueue(label: "app.icam.usbmux.listen")
    private var devices: [Int: USBDevice] = [:]
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        queue.async { self.listenLoop() }
    }

    private func listenLoop() {
        while running {
            do {
                let fd = try USBMux.openSocket()
                defer { Darwin.close(fd) }
                try USBMux.writeAll(fd, try USBMux.encode(USBMux.baseRequest("Listen"), tag: 1))
                let reply = try USBMux.readMessage(fd)
                guard (reply["Number"] as? Int) == 0 else {
                    throw USBMuxError.protocolError("Listen rejected: \(reply)")
                }
                log.info("Listening for USB devices")
                while running {
                    handle(try USBMux.readMessage(fd))
                }
            } catch {
                log.notice("usbmuxd listen error: \(String(describing: error), privacy: .public)")
            }
            if !devices.isEmpty {
                devices.removeAll()
                publish()
            }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["MessageType"] as? String {
        case "Attached":
            guard let properties = message["Properties"] as? [String: Any],
                  let id = (message["DeviceID"] as? Int) ?? (properties["DeviceID"] as? Int) else { return }
            // usbmuxd also reports Wi-Fi-synced devices; we only want cables.
            guard (properties["ConnectionType"] as? String) == "USB" else { return }
            let serial = (properties["SerialNumber"] as? String) ?? "\(id)"
            devices[id] = USBDevice(muxID: id, serialNumber: serial)
            log.info("USB device attached: \(serial, privacy: .public)")
            publish()
        case "Detached":
            guard let id = message["DeviceID"] as? Int, devices.removeValue(forKey: id) != nil else { return }
            log.info("USB device detached: \(id)")
            publish()
        default:
            break
        }
    }

    private func publish() {
        let snapshot = devices.values.sorted { $0.muxID < $1.muxID }
        DispatchQueue.main.async { self.onChange?(snapshot) }
    }
}
