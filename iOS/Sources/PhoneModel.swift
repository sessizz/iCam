//
//  PhoneModel.swift
//  iCam (iPhone)
//
//  UI-facing state and the glue between the network server and the
//  capture/encode pipeline.
//

import AVFoundation
import Observation
import UIKit
import os

@MainActor
@Observable
final class PhoneModel {

    // MARK: Observable state

    private(set) var host: ConnectedHost?
    private(set) var isStreaming = false
    private(set) var usbStatus: ListenerStatus = .starting
    private(set) var wifiStatus: ListenerStatus = .starting
    private(set) var camera = CameraCapture.Snapshot()
    private(set) var stats = PipelineStats()
    /// Frames the congestion control dropped since the last status message.
    @ObservationIgnored private var droppedSinceStatus = 0
    @ObservationIgnored private var sourceDroppedSinceStatus = 0
    private(set) var cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
    var isDimmed = false
    private(set) var deviceName: String = DeviceIdentity.deviceName

    let pipeline = StreamPipeline()

    // MARK: Private

    private let log = Logger(subsystem: "app.icam", category: "model")
    private let server = PeerServer()
    @ObservationIgnored private var settings: CameraSettings
    @ObservationIgnored private var dimTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var lastSentStatus: PhoneStatus?
    @ObservationIgnored private var started = false
    /// A start request that arrived before camera access was granted.
    @ObservationIgnored private var pendingConfig: StreamConfig?

    private static let settingsKey = "cameraSettings"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(CameraSettings.self, from: data) {
            settings = saved
        } else {
            settings = CameraSettings(lensID: CameraCapture.lensWide, zoom: 1, mirrored: false, stabilization: false)
        }

        server.identity = {
            (DeviceIdentity.deviceID, DeviceIdentity.deviceName, DeviceIdentity.modelIdentifier)
        }
        server.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        let pipeline = self.pipeline
        server.onFrameAck = { sequence in
            pipeline.acknowledge(sequence: sequence)
        }
        pipeline.send = { [server] data in
            server.send(data)
        }
        pipeline.onCameraStateChange = { [weak self] in
            DispatchQueue.main.async { self?.cameraStateChanged() }
        }
        pipeline.onStats = { [weak self] stats in
            DispatchQueue.main.async {
                self?.stats = stats
                self?.droppedSinceStatus += stats.droppedFrames
                self?.sourceDroppedSinceStatus += stats.sourceDroppedFrames
            }
        }

        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification,
                     ProcessInfo.thermalStateDidChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendStatus() }
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        requestCameraAccessIfNeeded()
        server.start(serviceName: DeviceIdentity.deviceName, deviceID: DeviceIdentity.deviceID)
        // Periodic status keeps battery/thermal info fresh on the Mac.
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if let self { self.camera = self.pipeline.camera.snapshot() }
                self?.sendStatus(force: true)
            }
        }
    }

    func didBecomeActive() {
        authorizationChanged()
        server.ensureListening()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func didEnterBackground() {
        // iOS doesn't allow camera capture in the background. Tell the Mac
        // via the status message; the connection will usually drop anyway.
        UIApplication.shared.isIdleTimerDisabled = false
        isDimmed = false
    }

    private func requestCameraAccessIfNeeded() {
        guard cameraAuthorization == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { [weak self] in
                self?.authorizationChanged()
            }
        }
    }

    private func authorizationChanged() {
        cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraAuthorization == .authorized, let config = pendingConfig, host != nil {
            startStreaming(config)
        } else {
            sendStatus()
        }
    }

    // MARK: Local controls (from the phone's own UI)

    func rename(to name: String) {
        DeviceIdentity.deviceName = name
        deviceName = DeviceIdentity.deviceName
        server.updateServiceName(deviceName)
    }

    func selectLens(_ id: String) {
        update(CameraSettings(lensID: id))
    }

    func setZoom(_ zoom: Double) {
        update(CameraSettings(zoom: zoom))
    }

    func userInteracted() {
        isDimmed = false
        scheduleDim()
    }

    // MARK: Event handling

    private func handle(_ event: PeerServer.Event) {
        switch event {
        case .listenerStatus(.usb, let status):
            usbStatus = status
        case .listenerStatus(.wifi, let status):
            wifiStatus = status
        case .connected(let host):
            self.host = host
            camera = pipeline.camera.snapshot()
            lastSentStatus = nil
            sendStatus(force: true)
        case .disconnected:
            host = nil
            stopStreaming()
        case .control(let message):
            handle(message)
        case .frameAck:
            break
        }
    }

    private func handle(_ message: ControlMessage) {
        switch message {
        case .startStream(let config):
            startStreaming(config)
        case .stopStream:
            stopStreaming()
        case .requestKeyFrame:
            pipeline.requestKeyFrame()
        case .updateSettings(let change):
            update(change)
        case .hello, .helloReply, .status, .ping, .pong:
            break
        }
    }

    private func startStreaming(_ config: StreamConfig) {
        guard cameraAuthorization == .authorized else {
            log.error("Camera access not granted")
            pendingConfig = config
            sendStatus(force: true)
            return
        }
        pendingConfig = nil
        pipeline.start(config: config, settings: settings, transport: host?.transport ?? .wifi)
        isStreaming = true
        userInteracted()
        sendStatus(force: true)
    }

    private func stopStreaming() {
        pendingConfig = nil
        guard isStreaming else { return }
        pipeline.stop()
        isStreaming = false
        isDimmed = false
        dimTask?.cancel()
        sendStatus(force: true)
    }

    private func update(_ change: CameraSettings) {
        if let lens = change.lensID { settings.lensID = lens; settings.zoom = 1 }
        if let zoom = change.zoom { settings.zoom = zoom }
        if let mirrored = change.mirrored { settings.mirrored = mirrored }
        if let stabilization = change.stabilization { settings.stabilization = stabilization }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        pipeline.apply(settings: change)
    }

    private func cameraStateChanged() {
        camera = pipeline.camera.snapshot()
        sendStatus()
    }

    private func scheduleDim() {
        dimTask?.cancel()
        guard isStreaming else { return }
        dimTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.isStreaming else { return }
            self.isDimmed = true
        }
    }

    // MARK: Status

    private func currentStatus() -> PhoneStatus {
        let device = UIDevice.current
        var interruption = camera.interruption
        if cameraAuthorization != .authorized {
            interruption = String(localized: "Camera access is off. Allow it in iPhone Settings › iCam.")
        }
        // Stats are only current while the camera produces frames.
        let linkStatsValid = isStreaming && camera.isRunning && stats.latencyMs > 0
        return PhoneStatus(
            lenses: camera.lenses,
            currentLensID: camera.currentLensID ?? settings.lensID,
            zoom: camera.zoom,
            mirrored: settings.mirrored ?? false,
            stabilization: settings.stabilization ?? false,
            isCapturing: isStreaming && camera.isRunning,
            isPortrait: camera.isPortrait,
            interruption: interruption,
            batteryLevel: device.batteryLevel,
            isCharging: device.batteryState == .charging || device.batteryState == .full,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            bitrate: pipeline.currentBitrate,
            roundTripMs: linkStatsValid ? Int(stats.latencyMs.rounded()) : nil,
            queueDelayMs: linkStatsValid ? Int(stats.queueDelayMs.rounded()) : nil,
            droppedFrames: isStreaming ? droppedSinceStatus : nil,
            sourceDroppedFrames: isStreaming ? sourceDroppedSinceStatus : nil)
    }

    private func sendStatus(force: Bool = false) {
        guard host != nil else { return }
        let status = currentStatus()
        guard force || status != lastSentStatus else { return }
        lastSentStatus = status
        droppedSinceStatus = 0
        sourceDroppedSinceStatus = 0
        server.send(.status(status))
    }
}
