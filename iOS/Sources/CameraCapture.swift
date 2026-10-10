//
//  CameraCapture.swift
//  iCam (iPhone)
//
//  Owns the AVCaptureSession. Produces upright 1920×1080 (or 1080×1920 when
//  the phone is held in portrait) 420v pixel buffers at a locked 30 fps.
//

import AVFoundation
import UIKit
import os

protocol CameraCaptureDelegate: AnyObject {
    /// Called on `CameraCapture.captureQueue` for every captured frame.
    func cameraCapture(_ capture: CameraCapture, didOutput pixelBuffer: CVPixelBuffer, presentationTime: CMTime)
    /// Called on an arbitrary queue whenever `snapshot()` would change.
    func cameraCaptureStateDidChange(_ capture: CameraCapture)
}

final class CameraCapture: NSObject {

    struct Snapshot: Equatable {
        var lenses: [LensInfo] = []
        var currentLensID: String?
        var zoom: Double = 1
        var mirrored = false
        var stabilization = false
        var isRunning = false
        var isPortrait = false
        var interruption: String?
    }

    static let lensUltraWide = "back-ultrawide"
    static let lensWide = "back-wide"
    static let lensTelephoto = "back-tele"
    static let lensFront = "front"

    let session = AVCaptureSession()
    let captureQueue = DispatchQueue(label: "icam.capture", qos: .userInteractive)
    weak var delegate: CameraCaptureDelegate?

    /// Invoked on the main queue when the active capture device changes, so
    /// the preview can rebuild its rotation coordinator.
    var onDeviceChange: ((AVCaptureDevice?) -> Void)?

    private let log = Logger(subsystem: "app.icam", category: "camera")
    private let sessionQueue = DispatchQueue(label: "icam.session", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var lensDevices: [String: AVCaptureDevice] = [:]
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var isConfigured = false
    private var notificationTokens: [NSObjectProtocol] = []

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    override init() {
        super.init()
        observeSessionNotifications()
        sessionQueue.async { self.discoverLenses() }
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func snapshot() -> Snapshot { state.withLock { $0 } }

    var currentDevice: AVCaptureDevice? { sessionQueue.sync { input?.device } }

    // MARK: Public control (all asynchronous, serialized on sessionQueue)

    func start(settings: CameraSettings) {
        sessionQueue.async {
            self.configureIfNeeded(settings: settings)
            self.apply(settingsOnQueue: settings)
            guard !self.session.isRunning else { return }
            self.session.startRunning()
            self.updateState { $0.isRunning = self.session.isRunning }
            self.log.info("Capture session started")
        }
    }

    func stop() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            self.updateState { $0.isRunning = false }
            self.log.info("Capture session stopped")
        }
    }

    func apply(_ settings: CameraSettings) {
        sessionQueue.async {
            self.apply(settingsOnQueue: settings)
        }
    }

    // MARK: Lenses

    private func discoverLenses() {
        let back = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back).devices
        let front = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .front).devices

        var devices: [String: AVCaptureDevice] = [:]
        for device in back {
            switch device.deviceType {
            case .builtInUltraWideCamera: devices[Self.lensUltraWide] = device
            case .builtInWideAngleCamera: devices[Self.lensWide] = device
            case .builtInTelephotoCamera: devices[Self.lensTelephoto] = device
            default: break
            }
        }
        if let front = front.first { devices[Self.lensFront] = front }
        lensDevices = devices

        let referenceFOV = devices[Self.lensWide].flatMap { Self.bestFormat(for: $0)?.videoFieldOfView }
        let order = [Self.lensUltraWide, Self.lensWide, Self.lensTelephoto, Self.lensFront]
        let lenses: [LensInfo] = order.compactMap { id in
            guard let device = devices[id] else { return nil }
            let format = Self.bestFormat(for: device)
            let maxZoom = Double(min(format?.videoMaxZoomFactor ?? 1, 5))
            let name: String
            let label: String
            switch id {
            case Self.lensUltraWide:
                name = "Ultra Wide"
                label = Self.zoomLabel(fov: format?.videoFieldOfView, reference: referenceFOV, fallback: 0.5)
            case Self.lensWide:
                name = "Wide"
                label = "1×"
            case Self.lensTelephoto:
                name = "Telephoto"
                label = Self.zoomLabel(fov: format?.videoFieldOfView, reference: referenceFOV, fallback: 2)
            default:
                name = "Front"
                label = "Front"
            }
            return LensInfo(id: id, name: name, label: label, maxZoom: maxZoom)
        }
        updateState { $0.lenses = lenses }
    }

    private static func zoomLabel(fov: Float?, reference: Float?, fallback: Double) -> String {
        var factor = fallback
        if let fov, let reference, fov > 0, reference > 0 {
            let toRadians = Float.pi / 180
            factor = Double(tan(reference * toRadians / 2) / tan(fov * toRadians / 2))
        }
        let rounded = factor < 1 ? (factor * 10).rounded() / 10 : (factor * 2).rounded() / 2
        return String(format: "%g×", rounded)
    }

    /// Picks the best 1920×1080 format that can run at exactly 30 fps.
    static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let fps = Double(ICam.frameRate)
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == Int32(ICam.outputWidth), dims.height == Int32(ICam.outputHeight) else { return false }
            return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && $0.maxFrameRate >= fps }
        }
        func score(_ format: AVCaptureDevice.Format) -> Int {
            var score = 0
            switch CMFormatDescriptionGetMediaSubType(format.formatDescription) {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: score += 40
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: score += 30
            default: break // 10-bit / ProRes / etc.
            }
            if !format.isVideoBinned { score += 10 }
            // Avoid high-frame-rate formats; they have worse noise behaviour.
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            if maxRate <= 60 { score += 5 }
            if format.supportedColorSpaces.contains(.sRGB) { score += 2 }
            return score
        }
        return candidates.max { score($0) < score($1) }
    }

    // MARK: Session configuration (sessionQueue)

    private func configureIfNeeded(settings: CameraSettings) {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        session.automaticallyConfiguresCaptureDeviceWideColor = false

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        } else {
            log.error("Cannot add video output")
        }
        session.commitConfiguration()

        let initialLens = settings.lensID ?? Self.lensWide
        switchLens(to: initialLens)
    }

    private func apply(settingsOnQueue settings: CameraSettings) {
        // Before the first start only remember connection options; lens and
        // zoom are applied by `start(settings:)`.
        let currentLens = input.flatMap { lensID(for: $0.device) }
        if isConfigured, let requested = settings.lensID, requested != currentLens {
            switchLens(to: requested)
        }
        if let mirrored = settings.mirrored {
            updateState { $0.mirrored = mirrored }
            applyConnectionSettings()
        }
        if let stabilization = settings.stabilization {
            updateState { $0.stabilization = stabilization }
            applyConnectionSettings()
        }
        if isConfigured, let zoom = settings.zoom {
            setZoom(zoom)
        }
    }

    private func lensID(for device: AVCaptureDevice) -> String? {
        lensDevices.first { $0.value.uniqueID == device.uniqueID }?.key
    }

    private func switchLens(to requestedID: String) {
        if lensDevices.isEmpty { discoverLenses() }
        let id = lensDevices[requestedID] != nil ? requestedID
            : (lensDevices[Self.lensWide] != nil ? Self.lensWide : lensDevices.keys.first)
        guard let id, let device = lensDevices[id] else {
            log.error("No camera available")
            updateState { $0.interruption = "No camera available" }
            return
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let input { session.removeInput(input) }
        input = nil

        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(newInput) else {
                log.error("Cannot add input for \(id, privacy: .public)")
                return
            }
            session.addInput(newInput)
            input = newInput
        } catch {
            log.error("Failed to create input: \(error.localizedDescription, privacy: .public)")
            return
        }

        configure(device: device)
        applyConnectionSettings()
        setupRotation(for: device)
        updateState {
            $0.currentLensID = id
            $0.zoom = 1
        }
        let callback = onDeviceChange
        DispatchQueue.main.async { callback?(device) }
    }

    private func configure(device: AVCaptureDevice) {
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(ICam.frameRate))
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if let format = Self.bestFormat(for: device) {
                device.activeFormat = format
                if format.supportedColorSpaces.contains(.sRGB) {
                    device.activeColorSpace = .sRGB
                }
                if format.isVideoHDRSupported {
                    device.automaticallyAdjustsVideoHDREnabled = false
                    device.isVideoHDREnabled = false
                }
            } else if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            }

            // Lock to a steady 30 fps like a real webcam.
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            device.videoZoomFactor = 1
        } catch {
            log.error("lockForConfiguration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyConnectionSettings() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        let snapshot = snapshot()
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = snapshot.mirrored
        }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = snapshot.stabilization ? .standard : .off
        }
    }

    private func setZoom(_ zoom: Double) {
        guard let device = input?.device else { return }
        let lensMax = snapshot().lenses.first { $0.id == lensID(for: device) }?.maxZoom ?? 5
        let upper = min(Double(device.maxAvailableVideoZoomFactor), lensMax)
        let lower = Double(device.minAvailableVideoZoomFactor)
        let clamped = max(lower, min(upper, zoom))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = CGFloat(clamped)
            device.unlockForConfiguration()
            updateState { $0.zoom = clamped }
        } catch {
            log.error("Zoom failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Rotation

    private func setupRotation(for device: AVCaptureDevice) {
        rotationObservation?.invalidate()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                  options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async { self?.applyRotation(angle) }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        if connection.videoRotationAngle != angle {
            connection.videoRotationAngle = angle
        }
        let portrait = Int(angle.rounded()) % 180 != 0
        updateState { $0.isPortrait = portrait }
    }

    // MARK: Notifications

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                                     object: session, queue: nil) { [weak self] note in
            let reasonValue = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = reasonValue.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            let text: String
            switch reason {
            case .videoDeviceNotAvailableInBackground: text = "iCam is in the background"
            case .videoDeviceInUseByAnotherClient: text = "Camera is in use by another app"
            case .videoDeviceNotAvailableWithMultipleForegroundApps: text = "Camera unavailable in Split View"
            case .videoDeviceNotAvailableDueToSystemPressure: text = "iPhone is too hot"
            default: text = "Camera interrupted"
            }
            self?.updateState { $0.interruption = text }
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                                     object: session, queue: nil) { [weak self] _ in
            self?.updateState { $0.interruption = nil }
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                     object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self.log.error("Capture runtime error: \(String(describing: error), privacy: .public)")
            // Media services reset or a transient failure: try to resume.
            self.sessionQueue.asyncAfter(deadline: .now() + 0.5) {
                if !self.session.isRunning && self.snapshot().isRunning {
                    self.session.startRunning()
                }
            }
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.didStartRunningNotification,
                                                     object: session, queue: nil) { [weak self] _ in
            self?.updateState { $0.isRunning = true; $0.interruption = nil }
        })
    }

    private func updateState(_ change: (inout Snapshot) -> Void) {
        let changed = state.withLock { snapshot -> Bool in
            let old = snapshot
            change(&snapshot)
            return old != snapshot
        }
        if changed { delegate?.cameraCaptureStateDidChange(self) }
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        delegate?.cameraCapture(self, didOutput: pixelBuffer,
                                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
