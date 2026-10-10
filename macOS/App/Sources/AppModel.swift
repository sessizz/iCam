//
//  AppModel.swift
//  iCam (Mac)
//

import AppKit
import AVFoundation
import Observation
import ServiceManagement
import SwiftUI
import os

@MainActor
@Observable
final class AppModel {

    let extensionManager = ExtensionManager()
    let devices = DeviceManager()

    private(set) var sinkState: VirtualCameraSink.State = .searching
    /// Some app is reading the virtual camera right now.
    private(set) var cameraInUse = false
    private(set) var stats = StreamStats()
    private(set) var sinkDiagnostics = VirtualCameraSink.Diagnostics()
    private(set) var cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private(set) var codec: VideoCodec
    private(set) var framing: PortraitFraming

    @ObservationIgnored let preview = PreviewFeed()
    @ObservationIgnored private let sink = VirtualCameraSink()
    @ObservationIgnored private let log = Logger(subsystem: "app.icam.mac", category: "app")
    @ObservationIgnored private var previewVisible = false
    @ObservationIgnored private var searchingSince: Date?
    @ObservationIgnored private var messageTimer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        codec = VideoCodec(rawValue: UserDefaults.standard.string(forKey: "codec") ?? "") ?? .h264
        framing = PortraitFraming(rawValue: UserDefaults.standard.string(forKey: "framing") ?? "") ?? .fill
    }

    var hasShownWelcome: Bool {
        defaults.bool(forKey: "didShowWelcome")
    }

    func markWelcomeShown() {
        defaults.set(true, forKey: "didShowWelcome")
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        if !defaults.bool(forKey: "didConfigureLoginItem") {
            defaults.set(true, forKey: "didConfigureLoginItem")
            setLaunchAtLogin(true, userInitiated: false)
        }

        extensionManager.activate()

        let sink = self.sink
        let preview = self.preview
        devices.codec = codec
        devices.pipeline.framing = framing
        devices.pipeline.cameraOutput = { buffer in sink.enqueue(buffer) }
        devices.pipeline.previewOutput = { buffer in preview.enqueue(buffer) }
        devices.pipeline.onStats = { [weak self] stats in
            MainActor.assumeIsolated { self?.stats = stats }
        }
        sink.onStateChange = { [weak self] state in
            MainActor.assumeIsolated { self?.sinkState = state }
        }
        sink.onDiagnostics = { [weak self] diagnostics in
            MainActor.assumeIsolated { self?.sinkDiagnostics = diagnostics }
        }
        sink.onDemandChange = { [weak self] inUse in
            MainActor.assumeIsolated {
                self?.cameraInUse = inUse
                self?.updateDemand()
            }
        }

        // Starting the virtual camera's input stream goes through the
        // camera privacy check, so ask for access first.
        if cameraAccess == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
                        sink.start()
                    }
                }
            }
        } else {
            sink.start()
        }

        devices.start()

        messageTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePlaceholderMessage()
                self?.relaunchIfCameraInvisible()
            }
        }
        updatePlaceholderMessage()
    }

    /// Called whenever the extension status changes to active.
    func extensionBecameActive() {
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        sink.refresh()
    }

    // MARK: Demand

    func setPreviewVisible(_ visible: Bool) {
        if visible {
            // Pick up permission changes made in System Settings meanwhile.
            let access = AVCaptureDevice.authorizationStatus(for: .video)
            if access != cameraAccess {
                cameraAccess = access
                sink.refresh()
            }
        }
        previewVisible = visible
        preview.isActive = visible
        updateDemand()
    }

    private func updateDemand() {
        devices.setDemand(cameraInUse || previewVisible)
    }

    // MARK: Settings

    func setCodec(_ newValue: VideoCodec) {
        guard newValue != codec else { return }
        codec = newValue
        defaults.set(newValue.rawValue, forKey: "codec")
        devices.codec = newValue
        devices.restartStreamIfNeeded()
    }

    func setFraming(_ newValue: PortraitFraming) {
        framing = newValue
        defaults.set(newValue.rawValue, forKey: "framing")
        devices.pipeline.framing = newValue
    }

    func setLaunchAtLogin(_ enabled: Bool, userInitiated: Bool = true) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
        }
        // Turned off by the user in System Settings: only they can re-enable it.
        if enabled, userInitiated, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func selectLens(_ id: String) {
        devices.send(settings: CameraSettings(lensID: id))
    }

    func setZoom(_ zoom: Double) {
        devices.send(settings: CameraSettings(zoom: zoom))
    }

    func setMirrored(_ mirrored: Bool) {
        devices.send(settings: CameraSettings(mirrored: mirrored))
    }

    func setStabilization(_ enabled: Bool) {
        devices.send(settings: CameraSettings(stabilization: enabled))
    }

    // MARK: Self relaunch

    private static let lastRelaunchKey = "lastRelaunchForMissingCamera"

    /// macOS doesn't show a camera extension to a process that was already
    /// running when the extension was activated or updated (it appears only
    /// after a relaunch). If the extension is active but its device stays
    /// invisible, relaunch once (at most every 10 minutes).
    private func relaunchIfCameraInvisible() {
        guard extensionManager.status == .active, sinkState == .searching else {
            searchingSince = nil
            return
        }
        let now = Date()
        guard let since = searchingSince else {
            searchingSince = now
            return
        }
        guard now.timeIntervalSince(since) > 4 else { return }
        let last = defaults.double(forKey: Self.lastRelaunchKey)
        guard now.timeIntervalSince1970 - last > 600 else { return }
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastRelaunchKey)
        log.notice("Virtual camera not visible to this process; relaunching")
        relaunch()
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: Diagnostics

    /// Plain-text snapshot of every stage between a video app and the
    /// iPhone, shown in the menu and copyable for bug reports.
    var diagnosticsReport: String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
        let d = sinkDiagnostics
        let demandProperty = d.demandProperty.map { "\"\($0)\"" } ?? "unreadable"
        let demandNotification = d.demandNotification.map { $0 ? "on" : "off" } ?? "none yet"
        let phone: String
        if let connected = devices.connected {
            phone = "\(connected.name) (\(connected.model)) via \(connected.transport.displayName)"
        } else {
            phone = "\(devices.state)"
        }
        var lines = [
            "iCam \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Extension: \(extensionManager.status)",
            "Mac camera access: \(cameraAccess.diagnosticName)",
            "Virtual camera input: \(d.state)",
            "AVFoundation sees iCam camera: \(d.avFoundationSeesCamera ? "yes" : "no")",
            "CoreMediaIO devices: \(d.cmioDevices.isEmpty ? "none" : d.cmioDevices.joined(separator: ", "))",
            "Camera streams: \(d.streams.isEmpty ? "none" : d.streams.joined(separator: "; "))",
            "Extension reports: \(d.extensionStatus ?? "unreadable")",
            "Demand property: \(demandProperty), notification: \(demandNotification)",
            "Camera in use by an app: \(cameraInUse ? "yes" : "no"), preview open: \(previewVisible ? "yes" : "no")",
            "iPhone: \(phone)",
            "Stream requested: \(devices.isStreaming ? "yes" : "no")",
        ]
        if let status = devices.phoneStatus {
            lines.append("iPhone capturing: \(status.isCapturing ? "yes" : "no")"
                         + (status.interruption.map { ", \($0)" } ?? ""))
        }
        lines.append(String(format: "From iPhone: %.0f fps, %.1f Mbps, %.0f ms RTT",
                            stats.fps, stats.bitrate / 1_000_000, stats.rttMs))
        lines.append("To virtual camera: \(d.framesPerSecond) fps, dropped \(d.droppedFrames)")
        if !d.lastAttempt.isEmpty {
            lines.append("Input attempt: \(d.lastAttempt.joined(separator: "; "))")
        }
        if let first = d.firstFailure {
            lines.append("First input failure: \(first) (\(d.failedAttempts) failed attempt(s))")
        }
        if let error = devices.lastError { lines.append("Last error: \(error)") }
        return lines.joined(separator: "\n")
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport, forType: .string)
    }

    // MARK: Placeholder

    private func updatePlaceholderMessage() {
        sink.setMessage(placeholderMessage())
    }

    private func placeholderMessage() -> String {
        if let interruption = devices.phoneStatus?.interruption {
            return interruption
        }
        switch devices.state {
        case .connected:
            let name = devices.connected?.name ?? "iPhone"
            return devices.isStreaming
                ? String(localized: "Starting \(name) camera…")
                : String(localized: "Connected to \(name)")
        case .connecting(let name):
            return String(localized: "Connecting to \(name)…")
        case .searching:
            if devices.isPaused {
                return String(localized: "Select your iPhone in the iCam menu")
            }
            if let error = devices.lastError {
                return error
            }
            return devices.phones.isEmpty
                ? String(localized: "Open iCam on your iPhone and connect it with a cable or Wi-Fi")
                : String(localized: "Open iCam on your iPhone")
        }
    }
}

private extension AVAuthorizationStatus {
    var diagnosticName: String {
        switch self {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }
}
