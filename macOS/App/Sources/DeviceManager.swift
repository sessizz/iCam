//
//  DeviceManager.swift
//  iCam (Mac)
//
//  Discovers iPhones (USB + Wi-Fi), keeps the best connection alive and
//  turns the iPhone camera on/off following the virtual camera's demand.
//
//  Policy
//  ------
//  * Preferred iPhone first (the one the user picked last), otherwise any.
//  * USB beats Wi-Fi. While connected over Wi-Fi, a USB tunnel to the same
//    phone is probed in the background and, if it works, takes over
//    seamlessly – the phone keeps streaming through the new connection.
//  * The camera runs only while some app uses the virtual camera (or the
//    preview is open), with a short grace period to avoid flapping.
//

import Foundation
import Observation
import os

struct ConnectedPhone: Equatable {
    var deviceID: String
    var name: String
    var model: String
    var transport: TransportKind
}

struct PhoneEntry: Identifiable, Equatable {
    var id: String
    var deviceID: String?
    var name: String
    var hasUSB: Bool
    var hasWiFi: Bool
    var isConnected: Bool
}

@MainActor
@Observable
final class DeviceManager {

    enum ConnectionState: Equatable {
        case searching
        case connecting(String)
        case connected
    }

    // MARK: Observable state

    private(set) var phones: [PhoneEntry] = []
    private(set) var connected: ConnectedPhone?
    private(set) var phoneStatus: PhoneStatus?
    private(set) var state: ConnectionState = .searching
    private(set) var lastError: String?
    private(set) var isStreaming = false
    private(set) var networkProblem: String?
    private(set) var usbAvailable = true

    /// Paused by the user ("Disconnect"); cleared by picking a phone.
    private(set) var isPaused = false

    // MARK: Dependencies

    @ObservationIgnored let pipeline = VideoPipeline()
    @ObservationIgnored var codec: VideoCodec = .h264

    // MARK: Private

    @ObservationIgnored private let log = Logger(subsystem: "app.icam.mac", category: "devices")
    @ObservationIgnored private let usbMonitor = USBDeviceMonitor()
    @ObservationIgnored private let browser = PhoneBrowser()
    @ObservationIgnored private var usbDevices: [USBDevice] = []
    @ObservationIgnored private var services: [BonjourPhone] = []
    @ObservationIgnored private var active: PhoneConnection?
    @ObservationIgnored private var attempt: PhoneConnection?
    @ObservationIgnored private var attemptKey: String?
    @ObservationIgnored private var probe: PhoneConnection?
    @ObservationIgnored private var probeKey: String?
    @ObservationIgnored private var usbConnectInFlight: Set<String> = []
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private var demand = false
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var serialToDeviceID: [String: String]
    @ObservationIgnored private var knownNames: [String: String]
    @ObservationIgnored private(set) var preferredDeviceID: String?

    @ObservationIgnored private let hostID: String
    @ObservationIgnored private let hostName = Host.current().localizedName ?? "Mac"

    init() {
        serialToDeviceID = defaults.dictionary(forKey: "usbSerialToDeviceID") as? [String: String] ?? [:]
        knownNames = defaults.dictionary(forKey: "knownPhoneNames") as? [String: String] ?? [:]
        preferredDeviceID = defaults.string(forKey: "preferredDeviceID")
        if let id = defaults.string(forKey: "hostID") {
            hostID = id
        } else {
            hostID = UUID().uuidString
            defaults.set(hostID, forKey: "hostID")
        }
    }

    func start() {
        usbMonitor.onChange = { [weak self] devices in
            MainActor.assumeIsolated {
                self?.usbDevices = devices
                self?.refresh()
            }
        }
        browser.onChange = { [weak self] phones in
            MainActor.assumeIsolated {
                self?.services = phones
                self?.refresh()
            }
        }
        browser.onProblem = { [weak self] problem in
            MainActor.assumeIsolated { self?.networkProblem = problem }
        }
        usbMonitor.start()
        browser.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: User actions

    func select(_ entry: PhoneEntry) {
        isPaused = false
        if let deviceID = entry.deviceID {
            preferredDeviceID = deviceID
            defaults.set(deviceID, forKey: "preferredDeviceID")
        }
        if let connected, connected.deviceID == entry.deviceID { return }
        dropAllConnections()
        retryAfter.removeAll()
        failures.removeAll()
        connect(to: entry)
    }

    func disconnect() {
        isPaused = true
        dropAllConnections()
        refresh()
    }

    func send(settings: CameraSettings) {
        active?.send(.updateSettings(settings))
    }

    func setDemand(_ wanted: Bool) {
        guard wanted != demand else { return }
        demand = wanted
        if wanted {
            stopTask?.cancel()
            stopTask = nil
            if let active, active.reply != nil, !isStreaming { startStream(on: active) }
        } else {
            // Grace period: apps often stop and immediately restart the
            // camera while switching formats.
            stopTask?.cancel()
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, !self.demand else { return }
                self.stopStream()
            }
        }
    }

    /// Restart the stream so new encoder settings (codec) take effect.
    func restartStreamIfNeeded() {
        guard isStreaming, let active else { return }
        startStream(on: active)
    }

    // MARK: Streaming

    private func streamConfig(for transport: TransportKind) -> StreamConfig {
        let (start, max): (Int, Int) = transport == .usb ? (14_000_000, 20_000_000) : (8_000_000, 12_000_000)
        let factor = codec == .hevc ? 0.7 : 1.0
        return StreamConfig(width: VirtualCamera.width, height: VirtualCamera.height, fps: VirtualCamera.frameRate,
                            codec: codec, bitrate: Int(Double(start) * factor),
                            maxBitrate: Int(Double(max) * factor))
    }

    private func startStream(on connection: PhoneConnection) {
        connection.send(.startStream(streamConfig(for: connection.kind)))
        isStreaming = true
        log.info("Requested stream over \(connection.kind.rawValue, privacy: .public)")
    }

    private func stopStream() {
        guard isStreaming else { return }
        active?.send(.stopStream)
        isStreaming = false
        let pipeline = self.pipeline
        PhoneConnection.queue.async { pipeline.reset() }
        log.info("Stopped stream")
    }

    // MARK: Connection policy

    private func refresh() {
        rebuildEntries()
        guard !isPaused else { return }

        // While a USB probe is in flight it may take over from a Wi-Fi
        // connection the phone just dropped in its favour; wait for it.
        if active == nil, attempt == nil, probe == nil, usbConnectInFlight.isEmpty {
            if let entry = bestCandidate() {
                connect(to: entry)
            } else {
                state = .searching
            }
        }

        // Upgrade Wi-Fi → USB when a cable shows up.
        if let active, active.kind == .wifi, probe == nil, usbConnectInFlight.isEmpty,
           let deviceID = connected?.deviceID,
           let usb = usbDevices.first(where: { serialToDeviceID[$0.serialNumber].map { $0 == deviceID } ?? true }),
           canAttempt(usbKey(usb)) {
            openUSB(usb, asProbe: true)
        }
    }

    private func bestCandidate() -> PhoneEntry? {
        let available = phones.filter { entry in
            (entry.hasUSB && usbDeviceFor(entry).map { canAttempt(usbKey($0)) } == true)
                || (entry.hasWiFi && serviceFor(entry).map { canAttempt(serviceKey($0)) } == true)
        }
        if let preferredDeviceID, let preferred = available.first(where: { $0.deviceID == preferredDeviceID }) {
            return preferred
        }
        return available.first { $0.hasUSB } ?? available.first
    }

    private func connect(to entry: PhoneEntry) {
        if let usb = usbDeviceFor(entry), canAttempt(usbKey(usb)) {
            openUSB(usb, asProbe: false)
        } else if let service = serviceFor(entry), canAttempt(serviceKey(service)) {
            openWiFi(service)
        }
    }

    private func openWiFi(_ service: BonjourPhone) {
        let key = serviceKey(service)
        let connection = PhoneConnection(transport: NetworkTransport(endpoint: service.endpoint),
                                         hello: makeHello(.wifi), serviceName: service.name)
        attempt = connection
        attemptKey = key
        state = .connecting(service.name)
        connection.onEvent = { [weak self] connection, event in
            MainActor.assumeIsolated { self?.handle(event, from: connection) }
        }
        connection.start()
        log.info("Connecting over Wi-Fi to \(service.name, privacy: .public)")
    }

    private func openUSB(_ device: USBDevice, asProbe: Bool) {
        let key = usbKey(device)
        usbConnectInFlight.insert(key)
        if !asProbe { state = .connecting(displayName(for: device)) }
        let hello = makeHello(.usb)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try USBMux.connect(to: device, port: ICam.tcpPort) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.usbConnectFinished(result, device: device, key: key, hello: hello, asProbe: asProbe)
                }
            }
        }
    }

    private func usbConnectFinished(_ result: Result<Int32, Error>, device: USBDevice, key: String,
                                    hello: HelloMessage, asProbe: Bool) {
        usbConnectInFlight.remove(key)
        switch result {
        case .failure(let error):
            // Usually "connection refused": iCam isn't open on the phone.
            log.debug("USB connect failed: \(String(describing: error), privacy: .public)")
            backOff(key)
            if !asProbe, case .connecting = state { state = .searching }
            refresh()
        case .success(let fd):
            // The world may have changed while connecting.
            if isPaused || (!asProbe && (active != nil || attempt != nil)) || (asProbe && active?.kind != .wifi) {
                Darwin.close(fd)
                return
            }
            let connection = PhoneConnection(transport: SocketTransport(fd: fd), hello: hello, usbDevice: device)
            connection.onEvent = { [weak self] connection, event in
                MainActor.assumeIsolated { self?.handle(event, from: connection) }
            }
            if asProbe {
                probe = connection
                probeKey = key
            } else {
                attempt = connection
                attemptKey = key
            }
            connection.start()
            log.info("USB tunnel open (\(asProbe ? "probe" : "primary", privacy: .public))")
        }
    }

    private func handle(_ event: PhoneConnection.Event, from connection: PhoneConnection) {
        switch event {
        case .ready(let reply):
            remember(reply, for: connection)
            if connection === attempt {
                attempt = nil
                attemptKey = nil
                activate(connection, reply: reply)
            } else if connection === probe {
                probe = nil
                probeKey = nil
                if active == nil || connected?.deviceID == reply.deviceID {
                    log.info("Switching to USB")
                    let old = active
                    activate(connection, reply: reply)
                    old?.onEvent = nil
                    old?.attach(nil)
                    old?.close()
                } else {
                    // A different iPhone is on the cable; leave it alone.
                    connection.onEvent = nil
                    connection.close()
                }
            } else {
                connection.close()
            }

        case .rejected(let reason):
            lastError = reason
            if let key = key(for: connection) { backOff(key, minimum: 5) }

        case .status(let status):
            guard connection === active else { return }
            phoneStatus = status

        case .closed(let reason):
            if connection === active {
                log.info("Lost iPhone: \(reason ?? "-", privacy: .public)")
                active = nil
                connected = nil
                phoneStatus = nil
                isStreaming = false
                let pipeline = self.pipeline
                PhoneConnection.queue.async { pipeline.reset() }
                if let key = key(for: connection) { backOff(key, minimum: 1) }
                state = .searching
            } else if connection === attempt {
                attempt = nil
                if let attemptKey { backOff(attemptKey) }
                attemptKey = nil
                if active == nil { state = .searching }
            } else if connection === probe {
                probe = nil
                if let probeKey { backOff(probeKey) }
                probeKey = nil
            }
            refresh()
        }
    }

    private func activate(_ connection: PhoneConnection, reply: HelloReply) {
        active = connection
        connection.attach(pipeline)
        connected = ConnectedPhone(deviceID: reply.deviceID, name: reply.deviceName,
                                   model: reply.deviceModel, transport: connection.kind)
        state = .connected
        lastError = nil
        isStreaming = false
        log.info("Connected to \(reply.deviceName, privacy: .public) via \(connection.kind.rawValue, privacy: .public)")
        if demand { startStream(on: connection) }
        rebuildEntries()
    }

    private func dropAllConnections() {
        for connection in [active, attempt, probe].compactMap({ $0 }) {
            connection.onEvent = nil
            connection.attach(nil)
            connection.close()
        }
        active = nil
        attempt = nil
        attemptKey = nil
        probe = nil
        probeKey = nil
        connected = nil
        phoneStatus = nil
        isStreaming = false
        state = .searching
        let pipeline = self.pipeline
        PhoneConnection.queue.async { pipeline.reset() }
    }

    private func remember(_ reply: HelloReply, for connection: PhoneConnection) {
        if let key = key(for: connection) {
            failures[key] = nil
            retryAfter[key] = nil
        }
        knownNames[reply.deviceID] = reply.deviceName
        defaults.set(knownNames, forKey: "knownPhoneNames")
        if let usb = connection.usbDevice {
            serialToDeviceID[usb.serialNumber] = reply.deviceID
            defaults.set(serialToDeviceID, forKey: "usbSerialToDeviceID")
        }
    }

    // MARK: Entries

    private func rebuildEntries() {
        var entries: [String: PhoneEntry] = [:]
        for service in services {
            let id = service.deviceID ?? "bonjour:\(service.name)"
            var entry = entries[id] ?? PhoneEntry(id: id, deviceID: service.deviceID, name: service.name,
                                                  hasUSB: false, hasWiFi: false, isConnected: false)
            entry.hasWiFi = true
            entry.name = service.name
            entries[id] = entry
        }
        for usb in usbDevices {
            let deviceID = serialToDeviceID[usb.serialNumber]
            let id = deviceID ?? "usb:\(usb.serialNumber)"
            var entry = entries[id] ?? PhoneEntry(id: id, deviceID: deviceID, name: displayName(for: usb),
                                                  hasUSB: false, hasWiFi: false, isConnected: false)
            entry.hasUSB = true
            entries[id] = entry
        }
        if let connected {
            var entry = entries[connected.deviceID] ?? PhoneEntry(
                id: connected.deviceID, deviceID: connected.deviceID, name: connected.name,
                hasUSB: connected.transport == .usb, hasWiFi: connected.transport == .wifi, isConnected: true)
            entry.isConnected = true
            entry.name = connected.name
            entries[connected.deviceID] = entry
        }
        let sorted = entries.values.sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        if sorted != phones { phones = sorted }
    }

    private func usbDeviceFor(_ entry: PhoneEntry) -> USBDevice? {
        usbDevices.first { usb in
            if let deviceID = serialToDeviceID[usb.serialNumber] { return deviceID == entry.deviceID }
            return entry.id == "usb:\(usb.serialNumber)"
        }
    }

    private func serviceFor(_ entry: PhoneEntry) -> BonjourPhone? {
        services.first { service in
            if let deviceID = service.deviceID { return deviceID == entry.deviceID }
            return entry.id == "bonjour:\(service.name)"
        }
    }

    private func displayName(for usb: USBDevice) -> String {
        serialToDeviceID[usb.serialNumber].flatMap { knownNames[$0] } ?? "iPhone"
    }

    // MARK: Helpers

    private func makeHello(_ transport: TransportKind) -> HelloMessage {
        HelloMessage(protocolVersion: ICam.protocolVersion, hostID: hostID, hostName: hostName, transport: transport)
    }

    private func usbKey(_ device: USBDevice) -> String { "usb:\(device.serialNumber)" }
    private func serviceKey(_ service: BonjourPhone) -> String { "wifi:\(service.name)" }

    private func key(for connection: PhoneConnection) -> String? {
        if let usb = connection.usbDevice { return usbKey(usb) }
        if let name = connection.serviceName { return "wifi:\(name)" }
        return nil
    }

    /// Exponential back-off per endpoint: 2 s, 4 s, 8 s, capped at 10 s.
    private func backOff(_ key: String, minimum: TimeInterval = 0) {
        let count = (failures[key] ?? 0) + 1
        failures[key] = count
        let delay = max(minimum, min(10, 2 * pow(2, Double(min(count, 4) - 1))))
        let date = Date().addingTimeInterval(delay)
        if let existing = retryAfter[key], existing > date { return }
        retryAfter[key] = date
    }

    private func canAttempt(_ key: String) -> Bool {
        guard let date = retryAfter[key] else { return true }
        return date <= Date()
    }
}
