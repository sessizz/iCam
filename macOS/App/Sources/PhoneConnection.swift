//
//  PhoneConnection.swift
//  iCam (Mac)
//
//  One protocol session with the iPhone app over a transport.
//

import Foundation
import QuartzCore
import os

final class PhoneConnection {

    enum Event {
        case ready(HelloReply)
        case rejected(String)
        case status(PhoneStatus)
        case closed(String?)
    }

    /// All connections share one serial queue, which also runs decoding, so
    /// a USB ↔ Wi-Fi hand-over can never interleave frames.
    static let queue = DispatchQueue(label: "app.icam.connection", qos: .userInteractive)

    let id = UUID()
    let transport: PhoneTransport
    var kind: TransportKind { transport.kind }
    let usbDevice: USBDevice?
    let serviceName: String?

    /// Main queue.
    var onEvent: ((PhoneConnection, Event) -> Void)?

    /// Set while this connection is the one feeding the virtual camera.
    /// Confined to `PhoneConnection.queue`; use `attach(_:)`.
    private var pipeline: VideoPipeline?

    private(set) var reply: HelloReply?

    private let log = Logger(subsystem: "app.icam.mac", category: "connection")
    private let parser = MessageParser()
    private var heartbeat: DispatchSourceTimer?
    private var lastReceived = CACurrentMediaTime()
    private var lastKeyFrameRequest: CFTimeInterval = 0
    private var closed = false
    private let hello: HelloMessage

    init(transport: PhoneTransport, hello: HelloMessage, usbDevice: USBDevice? = nil, serviceName: String? = nil) {
        self.transport = transport
        self.hello = hello
        self.usbDevice = usbDevice
        self.serviceName = serviceName
    }

    func start() {
        let queue = Self.queue
        queue.async { [self] in
            transport.start(queue: queue, onReady: { [weak self] in
                self?.didBecomeReady()
            }, onData: { [weak self] data in
                self?.receive(data)
            }, onClose: { [weak self] reason in
                self?.didClose(reason)
            })
        }
    }

    func attach(_ pipeline: VideoPipeline?) {
        Self.queue.async { self.pipeline = pipeline }
    }

    func send(_ message: ControlMessage) {
        transport.send(MessageFramer.frame(message))
    }

    func close() {
        transport.close()
    }

    // MARK: Private (queue)

    private func didBecomeReady() {
        lastReceived = CACurrentMediaTime()
        transport.send(MessageFramer.frame(.hello(hello)))
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now() + ICam.heartbeatInterval, repeating: ICam.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        heartbeat = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if now - lastReceived > ICam.livenessTimeout {
            log.notice("iPhone timed out")
            transport.close()
            return
        }
        // Hellos that are never answered (e.g. an old app) also time out.
        if reply == nil, now - lastReceived > 3 {
            transport.close()
            return
        }
        transport.send(MessageFramer.frame(.ping(PingMessage(t: now))))
    }

    private func receive(_ data: Data) {
        guard !closed else { return }
        lastReceived = CACurrentMediaTime()
        parser.append(data)
        do {
            while let message = try parser.next() {
                handle(message)
                if closed { return }
            }
        } catch {
            log.error("Protocol error: \(String(describing: error), privacy: .public)")
            transport.close()
        }
    }

    private func handle(_ message: InboundMessage) {
        switch message {
        case .videoFormat(let format):
            pipeline?.handleFormat(format)
        case .videoFrame(let frame):
            let ok = pipeline?.handleFrame(frame) ?? true
            // Ack after decoding so the iPhone's congestion control also
            // accounts for decode time on this Mac. Frames that arrive before
            // this connection is attached are acknowledged too, so the phone
            // never stalls waiting for them.
            transport.send(MessageFramer.frameAck(sequence: frame.sequence))
            if !ok { requestKeyFrame() }
        case .control(let control):
            handle(control)
        case .frameAck:
            break
        }
    }

    private func handle(_ control: ControlMessage) {
        switch control {
        case .helloReply(let reply):
            if reply.accepted {
                self.reply = reply
                emit(.ready(reply))
            } else {
                emit(.rejected(reply.reason ?? "The iPhone refused the connection."))
                transport.close()
            }
        case .status(let status):
            emit(.status(status))
        case .pong(let ping):
            pipeline?.updateRTT(CACurrentMediaTime() - ping.t)
        case .ping(let ping):
            transport.send(MessageFramer.frame(.pong(ping)))
        case .hello, .startStream, .stopStream, .requestKeyFrame, .updateSettings:
            break
        }
    }

    func requestKeyFrame() {
        Self.queue.async {
            let now = CACurrentMediaTime()
            guard now - self.lastKeyFrameRequest > 0.5 else { return }
            self.lastKeyFrameRequest = now
            self.transport.send(MessageFramer.frame(.requestKeyFrame))
        }
    }

    private func didClose(_ reason: String?) {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        heartbeat = nil
        log.info("Connection closed: \(reason ?? "-", privacy: .public)")
        emit(.closed(reason))
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async {
            self.onEvent?(self, event)
        }
    }
}
