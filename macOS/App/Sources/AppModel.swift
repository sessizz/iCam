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
    @ObservationIgnored private var lastRecordsRefresh = Date.distantPast
    @ObservationIgnored private var lastProbe = Date.distantPast
    @ObservationIgnored private var probeRunning = false
    /// The extension is active but its camera has stayed invisible to this
    /// process for a while.
    private(set) var cameraMissing = false
    /// Result of the latest fresh-process check while the camera was
    /// missing: true if a new process sees it, false if not, nil if unknown.
    private(set) var cameraVisibleToNewProcess: Bool?
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
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sinkState = state
                // The camera works again: a later disappearance gets a fresh
                // relaunch budget.
                if state == .ready { self.defaults.removeObject(forKey: Self.relaunchHistoryKey) }
            }
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

    private static let relaunchHistoryKey = "relaunchesForMissingCamera"
    /// Automatic relaunches allowed until the camera connects again (or an
    /// hour passes), so a camera that stays missing can't cause a loop.
    private static let maxRelaunches = 3

    /// The camera extension that serves apps reports a different build than
    /// the one bundled with this app: an older copy is still running.
    var extensionOutdated: Bool {
        guard let bundled = extensionManager.bundledVersion,
              let status = sinkDiagnostics.extensionStatus,
              status.hasPrefix("build "),
              let end = status.firstIndex(of: ";") else { return false }
        return status[status.index(status.startIndex, offsetBy: 6)..<end] != bundled
    }

    /// Automatic relaunches since the camera last connected (they span app
    /// instances).
    var recentRelaunches: Int { recentRelaunchTimes().count }

    private func recentRelaunchTimes() -> [Double] {
        let now = Date().timeIntervalSince1970
        return (defaults.array(forKey: Self.relaunchHistoryKey) as? [Double] ?? []).filter { now - $0 < 3600 }
    }

    /// The extension is active but its camera isn't visible to this process.
    /// A fresh process tells whether only this process's device list is
    /// stale (macOS doesn't show a camera extension to a process that was
    /// running when it was activated or updated; relaunching fixes it) or
    /// whether macOS didn't start the extension at all (relaunching can't
    /// help, so tell the user instead of looping).
    private func relaunchIfCameraInvisible() {
        guard extensionManager.status == .active, sinkState == .searching else {
            searchingSince = nil
            if cameraMissing { cameraMissing = false }
            if cameraVisibleToNewProcess != nil { cameraVisibleToNewProcess = nil }
            return
        }
        let now = Date()
        // Keep the extension list current for the menu and diagnostics.
        if now.timeIntervalSince(lastRecordsRefresh) > 10 {
            lastRecordsRefresh = now
            extensionManager.refreshSystemRecords()
        }
        guard let since = searchingSince else {
            searchingSince = now
            return
        }
        let invisibleFor = now.timeIntervalSince(since)
        if !cameraMissing, invisibleFor > 6 { cameraMissing = true }

        guard invisibleFor > 4, !probeRunning, now.timeIntervalSince(lastProbe) > 15 else { return }
        probeRunning = true
        CameraProbe.probe { [weak self] visible in
            MainActor.assumeIsolated { self?.handleProbe(visible) }
        }
    }

    private func handleProbe(_ visible: Bool?) {
        probeRunning = false
        lastProbe = Date()
        // The camera may have shown up meanwhile.
        guard extensionManager.status == .active, sinkState == .searching else { return }
        cameraVisibleToNewProcess = visible
        guard visible == true else {
            log.notice("Virtual camera not visible to a new process either (\(String(describing: visible)))")
            return
        }
        let history = recentRelaunchTimes()
        guard history.count < Self.maxRelaunches else { return }
        defaults.set(history + [Date().timeIntervalSince1970], forKey: Self.relaunchHistoryKey)
        log.notice("Virtual camera visible to a new process but not this one; relaunching")
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
                + (devices.activeInterface.map { " (\($0))" } ?? "")
        } else {
            phone = "\(devices.state)"
        }
        var lines = [
            "iCam \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Extension: \(extensionManager.status), bundled build \(extensionManager.bundledVersion ?? "?")"
                + (extensionManager.replacedDuringThisRun ? ", updated during this run" : ""),
            "Installed extension copies: "
                + (extensionManager.systemRecords.isEmpty ? "unknown"
                   : extensionManager.systemRecords.joined(separator: "; ")),
            "Automatic relaunches since the camera last connected: \(recentRelaunches)",
            "Camera visible to a new process: "
                + (cameraVisibleToNewProcess.map { $0 ? "yes" : "no" } ?? "not checked"),
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
            var link = String(format: "iPhone link: target %.1f Mbps", Double(status.bitrate) / 1_000_000)
            if let rtt = status.roundTripMs { link += ", frame round trip \(rtt) ms" }
            if let queue = status.queueDelayMs { link += ", queueing \(queue) ms" }
            if let dropped = status.droppedFrames { link += ", dropped \(dropped) frame(s) in ~5 s" }
            if let dropped = status.sourceDroppedFrames, dropped > 0 {
                link += " (+\(dropped) by camera/encoder)"
            }
            lines.append(link)
        }
        lines.append(String(format: "From iPhone: %.0f fps, %.1f Mbps, %.0f ms RTT, playout buffer %.0f ms",
                            stats.fps, stats.bitrate / 1_000_000, stats.rttMs, stats.playoutDelayMs))
        lines.append("To virtual camera: \(d.framesPerSecond) fps, dropped \(d.droppedFrames)/s (queue full)")
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
