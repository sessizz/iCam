//
//  PeerServer.swift
//  iCam (iPhone)
//
//  Accepts connections from the Mac app.
//
//  Two listeners are used:
//   * USB   – fixed port on the loopback interface. The Mac reaches it through
//             usbmuxd, the same USB tunnel Xcode and Finder use. Needs no
//             network or Local Network permission at all.
//   * Wi-Fi – any free port on all interfaces, advertised over Bonjour;
//             also over peer-to-peer Wi-Fi (AWDL) while no Mac is connected
//             over the network or USB. AWDL makes the radio leave the
//             network's channel regularly, which shows up as latency spikes
//             on the video stream, so it is only on while it may be needed.
//
//  Only one Mac is served at a time. A new connection from the *same* Mac
//  replaces the old one (e.g. Wi-Fi → USB hand-over); another Mac is turned
//  away while the current one is alive.
//

import Foundation
import Network
import QuartzCore
import os

struct ConnectedHost: Equatable {
    var hostID: String
    var hostName: String
    var transport: TransportKind
}

enum ListenerStatus: Equatable {
    case starting
    case ready
    case waiting(String)
    case failed(String)
}

final class PeerServer {

    enum Event {
        case listenerStatus(TransportKind, ListenerStatus)
        case connected(ConnectedHost)
        case disconnected
        case control(ControlMessage)
        case frameAck(UInt32)
    }

    /// Delivered on the main queue.
    var onEvent: ((Event) -> Void)?

    /// Supplies the hello reply fields; read on the network queue.
    var identity: () -> (deviceID: String, deviceName: String, model: String) = { ("", "iPhone", "iPhone") }

    private let log = Logger(subsystem: "app.icam", category: "server")
    private let queue = DispatchQueue(label: "icam.network", qos: .userInteractive)
    private var usbListener: NWListener?
    private var wifiListener: NWListener?
    private var serviceName = "iPhone"
    private var txtRecord = NWTXTRecord()
    private var pending: [ObjectIdentifier: PeerConnection] = [:]
    private var active: PeerConnection?
    private let activeForSending = OSAllocatedUnfairLock<PeerConnection?>(uncheckedState: nil)
    private var livenessTimer: DispatchSourceTimer?
    private var isRunning = false
    private var listenerReady: [TransportKind: Bool] = [:]
    private var wifiPeerToPeer = true
    private var peerToPeerWork: DispatchWorkItem?

    // MARK: Lifecycle

    func start(serviceName: String, deviceID: String) {
        queue.async {
            self.serviceName = serviceName
            self.txtRecord = NWTXTRecord(["id": deviceID, "proto": String(ICam.protocolVersion)])
            self.isRunning = true
            self.ensureListening()
            self.startLivenessTimer()
        }
    }

    /// Restarts any listener that isn't healthy (e.g. after returning from
    /// the background, where iOS may have torn sockets down).
    func ensureListening() {
        queue.async {
            guard self.isRunning else { return }
            if self.usbListener == nil || self.listenerReady[.usb] != true { self.startUSBListener() }
            if self.wifiListener == nil || self.listenerReady[.wifi] != true { self.startWiFiListener() }
        }
    }

    func updateServiceName(_ name: String) {
        queue.async {
            self.serviceName = name
            self.wifiListener?.service = NWListener.Service(name: name, type: ICam.bonjourServiceType,
                                                            domain: nil, txtRecord: self.txtRecord)
        }
    }

    /// Sends bytes to the active Mac. Safe from any thread.
    func send(_ data: Data) {
        activeForSending.withLockUnchecked { $0 }?.send(data)
    }

    func send(_ message: ControlMessage) {
        send(MessageFramer.frame(message))
    }

    // MARK: Listeners

    private func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    private func retire(_ listener: NWListener?) {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
    }

    private func startUSBListener() {
        retire(usbListener)
        let parameters = makeParameters()
        parameters.requiredInterfaceType = .loopback
        guard let port = NWEndpoint.Port(rawValue: ICam.tcpPort),
              let listener = try? NWListener(using: parameters, on: port) else {
            emit(.listenerStatus(.usb, .failed("Cannot open port \(ICam.tcpPort)")))
            scheduleRestart()
            return
        }
        configure(listener, transport: .usb)
        usbListener = listener
        listener.start(queue: queue)
    }

    private func startWiFiListener() {
        retire(wifiListener)
        let parameters = makeParameters()
        parameters.includePeerToPeer = wifiPeerToPeer
        guard let listener = try? NWListener(using: parameters, on: .any) else {
            emit(.listenerStatus(.wifi, .failed("Cannot create listener")))
            scheduleRestart()
            return
        }
        listener.service = NWListener.Service(name: serviceName, type: ICam.bonjourServiceType,
                                              domain: nil, txtRecord: txtRecord)
        configure(listener, transport: .wifi)
        wifiListener = listener
        listener.start(queue: queue)
    }

    private func configure(_ listener: NWListener, transport: TransportKind) {
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            if case .ready = state {
                self.listenerReady[transport] = true
            } else {
                self.listenerReady[transport] = false
            }
            switch state {
            case .setup:
                self.emit(.listenerStatus(transport, .starting))
            case .ready:
                self.log.info("\(transport.rawValue, privacy: .public) listener ready on \(String(describing: listener?.port), privacy: .public)")
                self.emit(.listenerStatus(transport, .ready))
            case .waiting(let error):
                self.log.notice("\(transport.rawValue, privacy: .public) listener waiting: \(error.localizedDescription, privacy: .public)")
                self.emit(.listenerStatus(transport, .waiting(error.localizedDescription)))
            case .failed(let error):
                self.log.error("\(transport.rawValue, privacy: .public) listener failed: \(error.localizedDescription, privacy: .public)")
                self.emit(.listenerStatus(transport, .failed(error.localizedDescription)))
                listener?.cancel()
                self.scheduleRestart()
            case .cancelled:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, transport: transport)
        }
    }

    private func scheduleRestart() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.ensureListening()
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection, transport: TransportKind) {
        let peer = PeerConnection(connection: connection, transport: transport, queue: queue)
        let id = ObjectIdentifier(peer)
        pending[id] = peer
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            self.handle(message, from: peer)
        }
        peer.onClose = { [weak self, weak peer] in
            guard let self, let peer else { return }
            self.pending[ObjectIdentifier(peer)] = nil
            if self.active === peer {
                self.setActive(nil)
                self.log.info("Mac disconnected")
                self.emit(.disconnected)
            }
        }
        peer.start()
        log.info("Incoming \(transport.rawValue, privacy: .public) connection from \(String(describing: connection.endpoint), privacy: .public)")
    }

    private func handle(_ message: InboundMessage, from peer: PeerConnection) {
        switch message {
        case .control(.hello(let hello)):
            handleHello(hello, from: peer)
        case .control(.ping(let ping)):
            peer.send(MessageFramer.frame(.pong(ping)))
        case .control(let control):
            guard peer === active else { return }
            emit(.control(control))
        case .frameAck(let sequence):
            guard peer === active else { return }
            // Acks arrive ~30×/s; forward straight to the pipeline instead
            // of hopping to the main queue.
            onFrameAck?(sequence)
        case .videoFormat, .videoFrame:
            break // Not expected from the Mac.
        }
    }

    /// Fast path for frame acknowledgements, called on the network queue.
    var onFrameAck: ((UInt32) -> Void)?

    private func handleHello(_ hello: HelloMessage, from peer: PeerConnection) {
        let me = identity()
        func reply(accepted: Bool, reason: String?) {
            let message = HelloReply(protocolVersion: ICam.protocolVersion, accepted: accepted, reason: reason,
                                     deviceID: me.deviceID, deviceName: me.deviceName, deviceModel: me.model)
            peer.send(MessageFramer.frame(.helloReply(message)))
        }

        guard hello.protocolVersion == ICam.protocolVersion else {
            reply(accepted: false, reason: String(localized: "Incompatible iCam version. Please update both apps."))
            peer.close(after: 0.5)
            return
        }

        if let current = active, current !== peer {
            if current.hostID != hello.hostID && current.isAlive {
                let other = current.hostName ?? String(localized: "another Mac")
                reply(accepted: false, reason: String(localized: "iPhone is in use by \(other)."))
                peer.close(after: 0.5)
                return
            }
            // Same Mac reconnecting (or the old peer is dead): hand over.
            log.info("Replacing existing connection")
            current.onClose = nil
            current.close()
        }

        peer.hostID = hello.hostID
        peer.hostName = hello.hostName
        pending[ObjectIdentifier(peer)] = nil
        setActive(peer)
        reply(accepted: true, reason: nil)
        log.info("Mac connected: \(hello.hostName, privacy: .public) via \(peer.transport.rawValue, privacy: .public)")
        emit(.connected(ConnectedHost(hostID: hello.hostID, hostName: hello.hostName, transport: peer.transport)))
    }

    private func setActive(_ peer: PeerConnection?) {
        active = peer
        activeForSending.withLockUnchecked { $0 = peer }
        updatePeerToPeer()
    }

    /// Advertise over peer-to-peer Wi-Fi only while no Mac is connected, or
    /// the connected one is reachable only that way. Restarting the listener
    /// leaves accepted connections alone.
    private func updatePeerToPeer() {
        let wanted: Bool
        if let active, active.transport == .wifi {
            // Unknown interface: keep peer-to-peer rather than risk cutting
            // off a Mac that is connected through it.
            let interface = Self.interfaceName(of: active.connection)
            wanted = interface.map { $0.hasPrefix("awdl") || $0.hasPrefix("llw") } ?? true
        } else {
            wanted = active == nil
        }
        peerToPeerWork?.cancel()
        peerToPeerWork = nil
        guard wanted != wifiPeerToPeer else { return }
        if wanted, active == nil {
            // A Mac that just lost the cable (or the network) usually comes
            // back over Wi-Fi within moments: keep the current listener and
            // its Bonjour registration up for it instead of re-registering
            // under a new port right now.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.active == nil else { return }
                self.peerToPeerWork = nil
                self.applyPeerToPeer(true)
            }
            peerToPeerWork = work
            queue.asyncAfter(deadline: .now() + 5, execute: work)
            return
        }
        applyPeerToPeer(wanted)
    }

    private func applyPeerToPeer(_ wanted: Bool) {
        guard wanted != wifiPeerToPeer else { return }
        wifiPeerToPeer = wanted
        log.info("Peer-to-peer Wi-Fi advertising \(wanted ? "on" : "off", privacy: .public)")
        if isRunning { restartWiFiListener() }
    }

    private static func interfaceName(of connection: NWConnection) -> String? {
        if let name = connection.currentPath?.availableInterfaces.first?.name { return name }
        if case .hostPort(host: .ipv6(let address), port: _) = connection.endpoint {
            return address.interface?.name
        }
        return nil
    }

    /// Starts the new listener only once the old one is gone, so its Bonjour
    /// registration doesn't clash with the new one (which would rename the
    /// service, e.g. "iPhone (2)").
    private func restartWiFiListener() {
        guard let old = wifiListener else {
            startWiFiListener()
            return
        }
        wifiListener = nil
        listenerReady[.wifi] = false
        old.newConnectionHandler = nil
        old.stateUpdateHandler = { [weak self] state in
            guard let self, case .cancelled = state, self.isRunning, self.wifiListener == nil else { return }
            self.startWiFiListener()
        }
        old.cancel()
    }

    private func startLivenessTimer() {
        guard livenessTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let active = self.active, !active.isAlive {
                self.log.notice("Mac timed out")
                active.close()
            }
            for peer in self.pending.values where peer.age > 5 {
                peer.close() // Never said hello.
            }
        }
        timer.resume()
        livenessTimer = timer
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }
}

// MARK: - PeerConnection

private final class PeerConnection {
    let connection: NWConnection
    let transport: TransportKind
    var hostID: String?
    var hostName: String?
    var onMessage: ((InboundMessage) -> Void)?
    var onClose: (() -> Void)?

    private let queue: DispatchQueue
    private let parser = MessageParser()
    private let createdAt = CACurrentMediaTime()
    private var lastReceived = CACurrentMediaTime()
    private var closed = false
    private let log = Logger(subsystem: "app.icam", category: "peer")

    init(connection: NWConnection, transport: TransportKind, queue: DispatchQueue) {
        self.connection = connection
        self.transport = transport
        self.queue = queue
    }

    var isAlive: Bool { !closed && CACurrentMediaTime() - lastReceived < ICam.livenessTimeout }
    var age: CFTimeInterval { CACurrentMediaTime() - createdAt }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.log.notice("Send failed: \(error.localizedDescription, privacy: .public)")
                self?.queue.async { self?.close() }
            }
        })
    }

    func close(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let callback = onClose
        onClose = nil
        onMessage = nil
        callback?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastReceived = CACurrentMediaTime()
                self.parser.append(data)
                do {
                    while let message = try self.parser.next() {
                        self.onMessage?(message)
                        if self.closed { return }
                    }
                } catch {
                    self.log.error("Protocol error: \(String(describing: error), privacy: .public)")
                    self.close()
                    return
                }
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receive()
        }
    }
}
