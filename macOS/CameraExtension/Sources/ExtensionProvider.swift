//
//  ExtensionProvider.swift
//  iCam Camera Extension
//
//  A CoreMediaIO camera extension that shows up as a regular webcam in every
//  app (FaceTime, Zoom, Teams, Meet in Chrome/Safari, OBS, QuickTime …).
//
//  The device has two streams:
//   * source – what video apps read: 1920×1080 or 1280×720, 420v, 30 fps.
//   * sink   – private input fed by the iCam Mac app with decoded iPhone
//              frames (IOSurface backed, so nothing is copied across the
//              process boundary).
//
//  Live frames are forwarded to the source the moment they arrive. While no
//  live video is available a placeholder frame is produced at 30 fps so apps
//  never see a frozen or missing camera.
//

import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import VideoToolbox
import os

private let demandProperty = CMIOExtensionProperty(
    rawValue: VirtualCamera.extensionPropertyName(VirtualCamera.demandSelector))
private let messageProperty = CMIOExtensionProperty(
    rawValue: VirtualCamera.extensionPropertyName(VirtualCamera.messageSelector))
private let statusProperty = CMIOExtensionProperty(
    rawValue: VirtualCamera.extensionPropertyName(VirtualCamera.statusSelector))

private let log = Logger(subsystem: "app.icam.extension", category: "camera")

private func hostTimeNow() -> CMTime {
    CMClockGetTime(CMClockGetHostTimeClock())
}

private func nanoseconds(_ time: CMTime) -> UInt64 {
    UInt64(max(0, CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value))
}

// MARK: - Provider

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource()
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {
        deviceSource.clientDisconnected(client)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer, .providerName]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = VirtualCamera.manufacturer
        }
        if properties.contains(.providerName) {
            providerProperties.name = "iCam"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {

    static let defaultMessage = "Open the iCam app on your Mac"

    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: SourceStream!
    private var sinkStream: SinkStream!

    let sourceSizes: [(width: Int, height: Int)] = [(1920, 1080), (1280, 720)]
    private(set) var sourceFormats: [CMIOExtensionStreamFormat] = []
    private(set) var sinkFormat: CMIOExtensionStreamFormat!
    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(VirtualCamera.frameRate))

    private let queue = DispatchQueue(label: "app.icam.extension.device", qos: .userInteractive)

    // Read from CMIO's property queue, so kept behind locks.
    private let demand = OSAllocatedUnfairLock(initialState: false)
    private let currentMessage = OSAllocatedUnfairLock(initialState: DeviceSource.defaultMessage)
    private let sinkReport = OSAllocatedUnfairLock(initialState: SinkReport())

    /// The extension's view of the sink connection, published to the app as
    /// the `status` property so its diagnostics show both sides.
    struct SinkReport {
        var authorization = "no sink client yet"
        var running = false
        var consumed = 0
        var sourceClients = 0
    }

    // State below is confined to `queue`.
    private var sourceClientCount = 0
    /// Clients that were allowed to start the source stream; used to recover
    /// the demand state if an app quits or crashes without stopping it.
    private var sourceClientIDs: Set<UUID> = []
    private let activeFormat = OSAllocatedUnfairLock(initialState: 0)
    private var heartbeatTicks = 0
    private var sinkClient: CMIOExtensionClient?
    private var sinkGeneration = 0
    private var sinkRunning = false
    private var lastLiveFrameNanos: UInt64 = 0
    private var placeholderTimer: DispatchSourceTimer?
    private var placeholder: CVPixelBuffer?
    private let renderer = PlaceholderRenderer()
    private var scaler: VTPixelTransferSession?
    private var scaledPool: CVPixelBufferPool?
    private var scaledPoolSize = (width: 0, height: 0)
    private var outputDescription: CMVideoFormatDescription?

    override init() {
        super.init()
        sourceFormats = sourceSizes.map { Self.makeFormat(width: $0.width, height: $0.height) }
        sinkFormat = Self.makeFormat(width: VirtualCamera.width, height: VirtualCamera.height)

        device = CMIOExtensionDevice(localizedName: VirtualCamera.deviceName,
                                     deviceID: VirtualCamera.deviceUUID,
                                     legacyDeviceID: nil, source: self)
        sourceStream = SourceStream(localizedName: VirtualCamera.deviceName,
                                    streamID: VirtualCamera.sourceStreamUUID, device: self)
        sinkStream = SinkStream(localizedName: VirtualCamera.sinkStreamName,
                                streamID: VirtualCamera.sinkStreamUUID, device: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &scaler)
        if let scaler {
            VTSessionSetProperty(scaler, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Trim)
        }
    }

    private static func makeFormat(width: Int, height: Int) -> CMIOExtensionStreamFormat {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       width: Int32(width), height: Int32(height),
                                       extensions: nil, formatDescriptionOut: &description)
        let duration = CMTime(value: 1, timescale: CMTimeScale(VirtualCamera.frameRate))
        return CMIOExtensionStreamFormat(formatDescription: description!, maxFrameDuration: duration,
                                         minFrameDuration: duration, validFrameDurations: nil)
    }

    // MARK: CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, demandProperty, statusProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = Int(kIOAudioDeviceTransportTypeVirtual)
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = VirtualCamera.model
        }
        if properties.contains(demandProperty) {
            deviceProperties.setPropertyState(
                CMIOExtensionPropertyState<AnyObject>(value: (isInDemand ? "1" : "0") as NSString),
                forProperty: demandProperty)
        }
        if properties.contains(statusProperty) {
            deviceProperties.setPropertyState(CMIOExtensionPropertyState<AnyObject>(value: statusLine as NSString),
                                              forProperty: statusProperty)
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Shared state accessors (any queue)

    var isInDemand: Bool { demand.withLock { $0 } }

    var statusLine: String {
        let report = sinkReport.withLock { $0 }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "build \(build); \(report.authorization); sink \(report.running ? "running" : "stopped"), "
            + "\(report.consumed) frames in; \(report.sourceClients) camera client(s)"
    }
    var message: String { currentMessage.withLock { $0 } }

    /// Lock-protected: read from CMIO callbacks, which must never block on
    /// `queue` (that queue calls back into CMIO and could deadlock).
    var currentActiveFormatIndex: Int { activeFormat.withLock { $0 } }

    func setActiveFormatIndex(_ index: Int) {
        guard sourceFormats.indices.contains(index) else { return }
        let changed = activeFormat.withLock { current -> Bool in
            guard current != index else { return false }
            current = index
            return true
        }
        guard changed else { return }
        queue.async {
            self.placeholder = nil
            self.outputDescription = nil
        }
    }

    func setMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = trimmed.isEmpty ? Self.defaultMessage : String(trimmed.prefix(120))
        let changed = currentMessage.withLock { current -> Bool in
            guard current != newValue else { return false }
            current = newValue
            return true
        }
        guard changed else { return }
        queue.async { self.placeholder = nil }
    }

    // MARK: Source stream (video apps)

    func authorizeSource(_ client: CMIOExtensionClient) -> Bool {
        queue.async { self.sourceClientIDs.insert(client.clientID) }
        return true
    }

    func sourceStarted() {
        queue.async {
            self.sourceClientCount += 1
            self.reportSourceClients()
            log.info("Source started, clients: \(self.sourceClientCount)")
            if self.sourceClientCount == 1 {
                self.startPlaceholderTimer()
                self.publishDemand(true)
            }
        }
    }

    func sourceStopped() {
        queue.async {
            self.sourceClientCount = max(0, self.sourceClientCount - 1)
            self.reportSourceClients()
            log.info("Source stopped, clients: \(self.sourceClientCount)")
            if self.sourceClientCount == 0 {
                self.placeholderTimer?.cancel()
                self.placeholderTimer = nil
                self.publishDemand(false)
            }
        }
    }

    private func reportSourceClients() {
        let count = sourceClientCount
        sinkReport.withLock { $0.sourceClients = count }
    }

    private func publishDemand(_ value: Bool) {
        demand.withLock { $0 = value }
        heartbeatTicks = 0
        let state = CMIOExtensionPropertyState<AnyObject>(value: (value ? "1" : "0") as NSString)
        sinkStream.stream.notifyPropertiesChanged([demandProperty: state])
        device.notifyPropertiesChanged([demandProperty: state])
        postDemandNotification(value)
        log.info("Demand: \(value)")
    }

    private func postDemandNotification(_ value: Bool) {
        let name = value ? VirtualCamera.demandOnNotification : VirtualCamera.demandOffNotification
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    // MARK: Sink stream (iCam app)

    func authorizeSink(_ client: CMIOExtensionClient) -> Bool {
        // Only the iCam app that ships this extension may feed frames.
        let extensionID = Bundle.main.bundleIdentifier ?? ""
        let appID = extensionID.components(separatedBy: ".").dropLast().joined(separator: ".")
        // Be lenient about how the identifier is spelled (team prefixes etc.)
        // but never let an unrelated app inject video.
        let allowed = appID.isEmpty || (client.signingID.map { $0.contains(appID) } ?? true)
        let signingID = client.signingID ?? "unsigned"
        let authorization = "sink client \(signingID) (pid \(client.pid)) \(allowed ? "allowed" : "rejected")"
        sinkReport.withLock { $0.authorization = authorization }
        if allowed {
            log.notice("Sink client \(signingID, privacy: .public) allowed")
            queue.async { self.sinkClient = client }
        } else {
            log.error("Rejected sink client \(signingID, privacy: .public), expected \(appID, privacy: .public)")
        }
        return allowed
    }

    func sinkStarted() {
        queue.async {
            guard self.sinkClient != nil else {
                log.error("Sink started without an authorized client")
                return
            }
            self.sinkRunning = true
            self.sinkGeneration += 1
            self.sinkReport.withLock { $0.running = true }
            log.notice("Sink started")
            self.consumeNext(generation: self.sinkGeneration)
        }
    }

    func sinkStopped() {
        queue.async {
            self.sinkRunning = false
            self.sinkGeneration += 1
            self.sinkReport.withLock { $0.running = false }
            log.notice("Sink stopped")
        }
        setMessage(Self.defaultMessage)
    }

    func clientDisconnected(_ client: CMIOExtensionClient) {
        queue.async {
            if self.sourceClientIDs.remove(client.clientID) != nil,
               self.sourceClientIDs.isEmpty, self.sourceClientCount > 0 {
                log.notice("Last camera client went away without stopping; resetting")
                self.sourceClientCount = 0
                self.reportSourceClients()
                self.placeholderTimer?.cancel()
                self.placeholderTimer = nil
                self.publishDemand(false)
            }
            guard let sinkClient = self.sinkClient, sinkClient.clientID == client.clientID else { return }
            self.sinkClient = nil
            self.sinkRunning = false
            self.sinkGeneration += 1
            self.sinkReport.withLock { $0.running = false }
            self.setMessage(Self.defaultMessage)
            log.info("iCam app disconnected")
        }
    }

    private func consumeNext(generation: Int) {
        guard sinkRunning, generation == sinkGeneration, let client = sinkClient else { return }
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, error in
            guard let self else { return }
            self.queue.async {
                guard generation == self.sinkGeneration else { return }
                if let sampleBuffer {
                    self.sinkReport.withLock { $0.consumed += 1 }
                    self.handleLive(sampleBuffer)
                    let output = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber,
                                                              hostTimeInNanoseconds: nanoseconds(hostTimeNow()))
                    self.sinkStream.stream.notifyScheduledOutputChanged(output)
                    self.consumeNext(generation: generation)
                } else {
                    // Nothing queued (CMIO reports an empty sink queue as an
                    // error too): look again shortly. Poll fast while some app
                    // reads the camera so frames are picked up within a few
                    // milliseconds, slowly otherwise.
                    _ = error
                    let delay: DispatchTimeInterval = self.sourceClientCount > 0
                        ? .milliseconds(4) : .milliseconds(40)
                    self.queue.asyncAfter(deadline: .now() + delay) {
                        self.consumeNext(generation: generation)
                    }
                }
            }
        }
    }

    // MARK: Frame output (queue)

    private func handleLive(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastLiveFrameNanos = nanoseconds(hostTimeNow())
        guard sourceClientCount > 0 else { return }

        let size = sourceSizes[currentActiveFormatIndex]
        if CVPixelBufferGetWidth(pixelBuffer) == size.width,
           CVPixelBufferGetHeight(pixelBuffer) == size.height,
           CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            send(pixelBuffer)
        } else if let scaled = scale(pixelBuffer, width: size.width, height: size.height) {
            send(scaled)
        }
    }

    private func scale(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        guard let scaler else { return nil }
        if scaledPool == nil || scaledPoolSize.width != width || scaledPoolSize.height != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            scaledPool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &scaledPool)
            scaledPoolSize = (width, height)
        }
        guard let scaledPool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, scaledPool, &output)
        guard let output else { return nil }
        CVBufferPropagateAttachments(source, output)
        guard VTPixelTransferSessionTransferImage(scaler, from: source, to: output) == noErr else { return nil }
        return output
    }

    private func send(_ pixelBuffer: CVPixelBuffer) {
        if outputDescription == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(outputDescription!, imageBuffer: pixelBuffer) {
            outputDescription = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &outputDescription)
        }
        guard let outputDescription else { return }

        let now = hostTimeNow()
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: now,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: outputDescription,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return }
        sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: nanoseconds(now))
    }

    private func startPlaceholderTimer() {
        placeholderTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: frameDuration.seconds, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.placeholderTick()
        }
        timer.resume()
        placeholderTimer = timer
    }

    private func placeholderTick() {
        // Heartbeat for the Darwin-notification demand channel (every ~2 s).
        heartbeatTicks += 1
        if heartbeatTicks >= VirtualCamera.frameRate * 2 {
            heartbeatTicks = 0
            postDemandNotification(true)
        }

        // Live video is flowing (or paused only briefly): keep showing it.
        let now = nanoseconds(hostTimeNow())
        guard now &- lastLiveFrameNanos > 1_000_000_000 else { return }

        if placeholder == nil {
            let size = sourceSizes[currentActiveFormatIndex]
            placeholder = renderer.render(message: message, width: size.width, height: size.height)
        }
        if let placeholder { send(placeholder) }
    }
}

// MARK: - Source stream

final class SourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let device: DeviceSource

    init(localizedName: String, streamID: UUID, device: DeviceSource) {
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { device.sourceFormats }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = device.currentActiveFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = device.frameDuration
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            device.setActiveFormatIndex(index)
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        device.authorizeSource(client)
    }

    func startStream() throws { device.sourceStarted() }

    func stopStream() throws { device.sourceStopped() }
}

// MARK: - Sink stream

final class SinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let device: DeviceSource

    init(localizedName: String, streamID: UUID, device: DeviceSource) {
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [device.sinkFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData,
         demandProperty, messageProperty]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = device.frameDuration
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = Int(VirtualCamera.sinkQueueSize)
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        if properties.contains(demandProperty) {
            streamProperties.setPropertyState(
                CMIOExtensionPropertyState<AnyObject>(value: (device.isInDemand ? "1" : "0") as NSString),
                forProperty: demandProperty)
        }
        if properties.contains(messageProperty) {
            streamProperties.setPropertyState(CMIOExtensionPropertyState<AnyObject>(value: device.message as NSString),
                                              forProperty: messageProperty)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let state = streamProperties.propertiesDictionary[messageProperty],
           let text = state.value as? String {
            device.setMessage(text)
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        device.authorizeSink(client)
    }

    func startStream() throws { device.sinkStarted() }

    func stopStream() throws { device.sinkStopped() }
}
