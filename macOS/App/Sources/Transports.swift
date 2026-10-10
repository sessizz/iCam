//
//  Transports.swift
//  iCam (Mac)
//
//  Byte-stream transports to the iPhone: a usbmuxd tunnel socket (USB) and
//  a Network.framework TCP connection (Wi-Fi / peer-to-peer Wi-Fi).
//

import Darwin
import Foundation
import Network
import os

protocol PhoneTransport: AnyObject {
    var kind: TransportKind { get }
    /// All callbacks are invoked on `queue`. `onClose` is called at most once.
    func start(queue: DispatchQueue, onReady: @escaping () -> Void, onData: @escaping (Data) -> Void,
               onClose: @escaping (String?) -> Void)
    /// Thread safe.
    func send(_ data: Data)
    func close()
}

// MARK: - Wi-Fi

final class NetworkTransport: PhoneTransport {
    let kind: TransportKind = .wifi
    private let connection: NWConnection
    private var queue: DispatchQueue?
    private var onData: ((Data) -> Void)?
    private var onClose: ((String?) -> Void)?
    private var didClose = false

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo
        connection = NWConnection(to: endpoint, using: parameters)
    }

    func start(queue: DispatchQueue, onReady: @escaping () -> Void, onData: @escaping (Data) -> Void,
               onClose: @escaping (String?) -> Void) {
        self.queue = queue
        self.onData = onData
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                onReady()
            case .waiting(let error):
                // Typically "connection refused": the app isn't listening.
                self?.finish(error.localizedDescription)
            case .failed(let error):
                self?.finish(error.localizedDescription)
            case .cancelled:
                self?.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.queue?.async { self?.finish(error.localizedDescription) } }
        })
    }

    func close() {
        queue?.async { self.finish(nil) }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.didClose else { return }
            if let data, !data.isEmpty { self.onData?(data) }
            if let error {
                self.finish(error.localizedDescription)
            } else if isComplete {
                self.finish("Connection closed by iPhone")
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ reason: String?) {
        guard !didClose else { return }
        didClose = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let callback = onClose
        onClose = nil
        onData = nil
        callback?(reason)
    }
}

// MARK: - USB

final class SocketTransport: PhoneTransport {
    let kind: TransportKind = .usb
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "app.icam.usb.write", qos: .userInteractive)
    private let closedFlag = OSAllocatedUnfairLock(initialState: false)
    private var readSource: DispatchSourceRead?
    private var queue: DispatchQueue?
    private var onClose: ((String?) -> Void)?
    private let bufferSize = 512 * 1024
    private let buffer: UnsafeMutableRawPointer

    /// Takes ownership of `fd`, an established usbmuxd tunnel.
    init(fd: Int32) {
        self.fd = fd
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var size: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    deinit {
        buffer.deallocate()
    }

    func start(queue: DispatchQueue, onReady: @escaping () -> Void, onData: @escaping (Data) -> Void,
               onClose: @escaping (String?) -> Void) {
        self.queue = queue
        self.onClose = onClose
        let fd = self.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let n = Darwin.read(fd, self.buffer, self.bufferSize)
                if n > 0 {
                    onData(Data(bytes: self.buffer, count: n))
                    if n < self.bufferSize { return }
                    continue
                }
                if n == 0 {
                    self.finish("Connection closed by iPhone")
                } else if errno != EAGAIN && errno != EINTR {
                    self.finish(String(cString: strerror(errno)))
                }
                return
            }
        }
        let writeQueue = self.writeQueue
        source.setCancelHandler {
            // Close only after queued writes are done (they check the flag).
            writeQueue.async { Darwin.close(fd) }
        }
        readSource = source
        source.resume()
        queue.async { onReady() }
    }

    func send(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self, !self.closedFlag.withLock({ $0 }) else { return }
            if !self.writeAll(data) {
                self.queue?.async { self.finish("USB write failed") }
            }
        }
    }

    func close() {
        queue?.async { self.finish(nil) }
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                if closedFlag.withLock({ $0 }) { return false }
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 100)
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func finish(_ reason: String?) {
        let alreadyClosed = closedFlag.withLock { closed -> Bool in
            defer { closed = true }
            return closed
        }
        guard !alreadyClosed else { return }
        shutdown(fd, SHUT_RDWR)
        if let readSource {
            readSource.cancel() // closes the descriptor in its cancel handler
        } else {
            let fd = self.fd
            writeQueue.async { Darwin.close(fd) }
        }
        readSource = nil
        let callback = onClose
        onClose = nil
        callback?(reason)
    }
}
