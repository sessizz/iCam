//
//  VirtualCameraSink.swift
//  iCam (Mac)
//
//  Feeds decoded frames into the camera extension's sink stream through the
//  CoreMediaIO C API, and watches whether any app is using the camera.
//

import AVFoundation
import CoreMediaIO
import os

/// Internally confined to its own serial queue.
final class VirtualCameraSink: @unchecked Sendable {

    enum State: Equatable {
        case searching
        case ready
        case failed(String)
    }

    /// What the menu's diagnostics section shows.
    struct Diagnostics: Equatable {
        var state: State = .searching
        /// Raw value of the extension's demand property: "1", "0", or nil
        /// when it can't be read.
        var demandProperty: String?
        /// Last demand state received via Darwin notification, nil if none.
        var demandNotification: Bool?
        var framesPerSecond = 0
        var droppedFrames = 0
        /// Whether AVFoundation lists the iCam camera in this process.
        var avFoundationSeesCamera = false
        /// Names of all CoreMediaIO devices visible to this process.
        var cmioDevices: [String] = []
        /// The virtual camera's streams as CoreMediaIO lists them.
        var streams: [String] = []
        /// Result of each stream tried by the latest connection attempt.
        var lastAttempt: [String] = []
        /// The very first failure since launch; later retries can fail
        /// differently because of it.
        var firstFailure: String?
        var failedAttempts = 0
        /// The extension's own report (`status` property), nil if unreadable.
        var extensionStatus: String?
    }

    /// Main queue.
    var onStateChange: ((State) -> Void)?
    /// Main queue. True while at least one app reads the virtual camera.
    var onDemandChange: ((Bool) -> Void)?
    /// Main queue, about once per second.
    var onDiagnostics: ((Diagnostics) -> Void)?

    private let log = Logger(subsystem: "app.icam.mac", category: "sink")
    private let queue = DispatchQueue(label: "app.icam.sink", qos: .userInteractive)

    // Confined to `queue`.
    private var deviceID: CMIOObjectID = 0
    /// The virtual camera device last found, connected or not; used to read
    /// its properties for diagnostics even when the sink can't be started.
    private var knownDeviceID: CMIOObjectID = 0
    private var nextConnectTime: CFAbsoluteTime = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var bufferQueue: CMSimpleQueue?
    private var formatDescription: CMVideoFormatDescription?
    private var demand = false
    private var pollTimer: DispatchSourceTimer?
    private var pendingMessage: String?
    private var lastMessage: String?
    private var devicesListenerInstalled = false
    private var state: State = .searching
    private var pollTicks = 0
    private var propertyDemand = false
    /// Darwin-notification demand is a lease kept alive by the extension's
    /// heartbeat, so a lost "off" can't keep the iPhone camera on forever.
    private var notificationDemandUntil: CFAbsoluteTime = 0
    private var diagnostics = Diagnostics()
    private var framesThisSecond = 0
    private var droppedFrames = 0
    private var darwinObserversInstalled = false
    private var avObserver: NSObjectProtocol?

    // MARK: Lifecycle

    func start() {
        installDarwinObservers()
        // A camera extension that becomes available later shows up as a newly
        // connected AVCaptureDevice; use that as a cue to look again.
        avObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] _ in
            self?.refresh()
        }
        queue.async {
            self.installDevicesListener()
            self.connect()
            self.startPolling()
        }
    }

    /// Re-scan for the device, e.g. right after the extension was activated.
    func refresh() {
        queue.async {
            self.nextConnectTime = 0
            self.connect()
        }
    }

    func stop() {
        queue.sync {
            self.disconnect()
            self.pollTimer?.cancel()
            self.pollTimer = nil
        }
    }

    // MARK: Frames

    /// Hands a frame to the extension. Called from the video pipeline queue.
    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        queue.async { self.enqueueOnQueue(pixelBuffer) }
    }

    private func enqueueOnQueue(_ pixelBuffer: CVPixelBuffer) {
        guard let bufferQueue else { return }
        if CMSimpleQueueGetCount(bufferQueue) >= CMSimpleQueueGetCapacity(bufferQueue) {
            droppedFrames += 1
            return
        }

        if formatDescription == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            formatDescription = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(VirtualCamera.frameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                       formatDescription: formatDescription,
                                                       sampleTiming: &timing,
                                                       sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return }

        // The queue takes ownership of one reference; the extension side
        // releases it after consuming.
        let element = Unmanaged.passRetained(sampleBuffer).toOpaque()
        if CMSimpleQueueEnqueue(bufferQueue, element: element) != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
            droppedFrames += 1
        } else {
            framesThisSecond += 1
        }
    }

    // MARK: Placeholder message

    func setMessage(_ text: String) {
        queue.async {
            self.pendingMessage = text
            self.flushMessage()
        }
    }

    private func flushMessage() {
        guard sinkStreamID != 0, let text = pendingMessage, text != lastMessage else { return }
        var address = Self.customAddress(VirtualCamera.messageSelector)
        var value = text as CFString
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectSetPropertyData(sinkStreamID, &address, 0, nil,
                                      UInt32(MemoryLayout<CFString>.size), pointer)
        }
        if status == noErr {
            lastMessage = text
        } else {
            log.error("Setting placeholder message failed: \(status)")
        }
    }

    // MARK: Device discovery

    private func connect() {
        guard bufferQueue == nil, CFAbsoluteTimeGetCurrent() >= nextConnectTime else { return }
        guard let device = findDevice() else {
            update(state: .searching)
            return
        }
        let streams = describeStreams(of: device)
        diagnostics.streams = streams.map(\.summary)
        let candidates = sinkCandidates(streams)
        guard !candidates.isEmpty else {
            update(state: .failed("Camera extension has no input stream"))
            return
        }

        var results: [String] = []
        var lastStatus: OSStatus = noErr
        for stream in candidates {
            switch open(stream, on: device) {
            case .success(let simpleQueue):
                deviceID = device
                sinkStreamID = stream.id
                bufferQueue = simpleQueue
                formatDescription = nil
                lastMessage = nil
                diagnostics.lastAttempt = results + ["\(stream.summary): started"]
                log.notice("Connected to virtual camera sink \(stream.summary, privacy: .public)")
                update(state: .ready)
                installDemandListener()
                flushMessage()
                pollDemand()
                return
            case .failure(let failure):
                lastStatus = failure.status
                let text = "\(stream.summary): \(failure.step) failed (\(failure.status))"
                results.append(text)
                log.error("Virtual camera sink: \(text, privacy: .public)")
            }
        }

        // Every stream refused. Back off (2 s doubling to 30 s) so a stuck
        // system service isn't hammered; refresh() retries immediately.
        diagnostics.failedAttempts += 1
        diagnostics.lastAttempt = results
        if diagnostics.firstFailure == nil {
            diagnostics.firstFailure = results.joined(separator: "; ")
        }
        let delay = min(30, 2 * pow(2, Double(min(diagnostics.failedAttempts - 1, 4))))
        nextConnectTime = CFAbsoluteTimeGetCurrent() + delay
        update(state: .failed("Cannot start the virtual camera input (\(lastStatus))"))
    }

    private struct OpenFailure: Error {
        let step: String
        let status: OSStatus
    }

    /// Registers for the stream's buffer queue and starts it.
    private func open(_ stream: StreamInfo, on device: CMIOObjectID) -> Result<CMSimpleQueue, OpenFailure> {
        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var status = CMIOStreamCopyBufferQueue(stream.id, { _, _, _ in
            // Called when the extension consumed a buffer. Nothing to do: we
            // check the queue's fill level before every enqueue.
        }, refcon, &unmanagedQueue)
        guard status == noErr, let unmanagedQueue else {
            return .failure(OpenFailure(step: "CopyBufferQueue", status: status))
        }
        let simpleQueue = unmanagedQueue.takeRetainedValue()

        status = CMIODeviceStartStream(device, stream.id)
        guard status == noErr else {
            // Drop the registration so the next attempt starts clean.
            var released: Unmanaged<CMSimpleQueue>?
            if CMIOStreamCopyBufferQueue(stream.id, nil, nil, &released) == noErr {
                released?.release()
            }
            return .failure(OpenFailure(step: "StartStream", status: status))
        }
        return .success(simpleQueue)
    }

    private func disconnect() {
        if deviceID != 0, sinkStreamID != 0 {
            CMIODeviceStopStream(deviceID, sinkStreamID)
        }
        deviceID = 0
        sinkStreamID = 0
        bufferQueue = nil
        formatDescription = nil
        propertyDemand = false
        recomputeDemand()
    }

    /// Looks the camera up through AVFoundation first. Besides giving us the
    /// device's unique ID, this makes the process load CoreMediaIO extension
    /// devices; without it the C API can return an empty device list.
    private func findAVFoundationCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.external]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                       position: .unspecified).devices
        let wanted = VirtualCamera.deviceUUID.uuidString
        return devices.first { $0.uniqueID.caseInsensitiveCompare(wanted) == .orderedSame }
            ?? devices.first { $0.localizedName == VirtualCamera.deviceName }
    }

    private func findDevice() -> CMIOObjectID? {
        let avCamera = findAVFoundationCamera()
        diagnostics.avFoundationSeesCamera = avCamera != nil
        var wantedUIDs = [VirtualCamera.deviceUUID.uuidString.uppercased()]
        if let uid = avCamera?.uniqueID.uppercased(), !wantedUIDs.contains(uid) { wantedUIDs.append(uid) }

        var address = Self.address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            diagnostics.cmioDevices = []
            return nil
        }
        var devices = [CMIOObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, dataSize, &used, &devices) == noErr else {
            return nil
        }

        var nameMatch: CMIOObjectID?
        var uidMatch: CMIOObjectID?
        var names: [String] = []
        for device in devices {
            let name = Self.stringProperty(device, CMIOObjectPropertySelector(kCMIOObjectPropertyName))
            names.append(name ?? "?")
            if uidMatch == nil,
               let uid = Self.stringProperty(device, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)),
               wantedUIDs.contains(uid.uppercased()) {
                uidMatch = device
            }
            if name == VirtualCamera.deviceName {
                nameMatch = device
            }
        }
        diagnostics.cmioDevices = names
        knownDeviceID = uidMatch ?? nameMatch ?? 0
        return uidMatch ?? nameMatch
    }

    /// One stream of the virtual camera device as CoreMediaIO reports it.
    private struct StreamInfo {
        let id: CMIOStreamID
        let index: Int
        let name: String?
        let direction: UInt32?
        let hasMessageProperty: Bool

        var summary: String {
            "#\(index) \"\(name ?? "?")\" (id \(id), direction \(direction.map(String.init) ?? "?")"
                + (hasMessageProperty ? ", iCam input property)" : ")")
        }
    }

    private func describeStreams(of device: CMIOObjectID) -> [StreamInfo] {
        var address = Self.address(CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }
        var streams = [CMIOStreamID](repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOStreamID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &used, &streams) == noErr else {
            return []
        }
        return streams.enumerated().map { index, stream -> StreamInfo in
            var directionAddress = Self.address(CMIOObjectPropertySelector(kCMIOStreamPropertyDirection))
            var direction: UInt32 = 0
            var directionUsed: UInt32 = 0
            let hasDirection = CMIOObjectGetPropertyData(stream, &directionAddress, 0, nil,
                                                         UInt32(MemoryLayout<UInt32>.size),
                                                         &directionUsed, &direction) == noErr
            var messageAddress = Self.customAddress(VirtualCamera.messageSelector)
            return StreamInfo(id: stream, index: index,
                              name: Self.stringProperty(stream, CMIOObjectPropertySelector(kCMIOObjectPropertyName)),
                              direction: hasDirection ? direction : nil,
                              hasMessageProperty: CMIOObjectHasProperty(stream, &messageAddress))
        }
    }

    /// The streams that may be the extension's input, most likely first.
    /// The extension names its input stream and gives only it the custom
    /// message property; it also adds it second, which is what OBS relies on
    /// for its own extension. The stream video apps read is never a
    /// candidate: starting it would make this app a camera client.
    private func sinkCandidates(_ streams: [StreamInfo]) -> [StreamInfo] {
        func score(_ stream: StreamInfo) -> Int {
            (stream.name == VirtualCamera.sinkStreamName ? 8 : 0)
                + (stream.hasMessageProperty ? 4 : 0)
                + (stream.index == 1 ? 2 : 0)
        }
        return streams
            .filter { $0.name != VirtualCamera.deviceName && score($0) > 0 }
            .sorted { score($0) > score($1) }
    }

    private func installDevicesListener() {
        guard !devicesListenerInstalled else { return }
        devicesListenerInstalled = true
        var address = Self.address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue) { [weak self] _, _ in
            guard let self else { return }
            // The extension may have been replaced or removed.
            if self.deviceID != 0, self.findDevice() != self.deviceID {
                self.log.info("Virtual camera device changed; reconnecting")
                self.disconnect()
            }
            self.nextConnectTime = 0
            self.connect()
        }
    }

    // MARK: Demand

    private func installDemandListener() {
        var address = Self.customAddress(VirtualCamera.demandSelector)
        let stream = sinkStreamID
        CMIOObjectAddPropertyListenerBlock(stream, &address, queue) { [weak self] _, _ in
            self?.pollDemand()
        }
    }

    private func startPolling() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pollTicks += 1
            if self.bufferQueue == nil, self.pollTicks % 8 == 0 {
                // Device enumeration is comparatively expensive; the device
                // list listener covers the common case, this is a fallback.
                self.connect()
            }
            self.pollDemand()
            if self.pollTicks % 4 == 0 { self.publishDiagnostics() }
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollDemand() {
        let device = deviceID != 0 ? deviceID : knownDeviceID
        guard device != 0 else {
            recomputeDemand()
            return
        }
        let selector = VirtualCamera.fourCharCode(VirtualCamera.demandSelector)
        // The extension publishes demand on both the sink stream and the
        // device; use whichever this macOS version exposes.
        let value = (sinkStreamID != 0 ? Self.stringProperty(sinkStreamID, selector) : nil)
            ?? Self.stringProperty(device, selector)
        diagnostics.demandProperty = value
        propertyDemand = value == "1"
        recomputeDemand()
    }

    private func recomputeDemand() {
        let leased = notificationDemandUntil > CFAbsoluteTimeGetCurrent()
        setDemand(propertyDemand || leased)
    }

    // MARK: Darwin notifications (second demand channel)

    private func installDarwinObservers() {
        guard !darwinObserversInstalled else { return }
        darwinObserversInstalled = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let sink = Unmanaged<VirtualCameraSink>.fromOpaque(observer).takeUnretainedValue()
            sink.handleDarwinNotification(name.rawValue as String)
        }
        for name in [VirtualCamera.demandOnNotification, VirtualCamera.demandOffNotification] {
            CFNotificationCenterAddObserver(center, observer, callback, name as CFString, nil, .deliverImmediately)
        }
    }

    private func handleDarwinNotification(_ name: String) {
        queue.async {
            let on = name == VirtualCamera.demandOnNotification
            self.diagnostics.demandNotification = on
            // The extension repeats "on" every ~2 s while in use.
            self.notificationDemandUntil = on ? CFAbsoluteTimeGetCurrent() + 5 : 0
            if !on { self.propertyDemand = false }
            self.recomputeDemand()
        }
    }

    private func publishDiagnostics() {
        let device = deviceID != 0 ? deviceID : knownDeviceID
        diagnostics.extensionStatus = device == 0 ? nil
            : Self.stringProperty(device, VirtualCamera.fourCharCode(VirtualCamera.statusSelector))
        diagnostics.state = state
        diagnostics.framesPerSecond = framesThisSecond
        diagnostics.droppedFrames = droppedFrames
        framesThisSecond = 0
        let snapshot = diagnostics
        let callback = onDiagnostics
        DispatchQueue.main.async { callback?(snapshot) }
    }

    private func setDemand(_ newValue: Bool) {
        guard newValue != demand else { return }
        demand = newValue
        log.info("Virtual camera demand: \(newValue)")
        let callback = onDemandChange
        DispatchQueue.main.async { callback?(newValue) }
    }

    private func update(state newState: State) {
        guard newState != state else { return }
        state = newState
        let callback = onStateChange
        DispatchQueue.main.async { callback?(newState) }
    }

    // MARK: CMIO helpers

    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func customAddress(_ selector: String) -> CMIOObjectPropertyAddress {
        Self.address(VirtualCamera.fourCharCode(selector))
    }

    private static func stringProperty(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> String? {
        var propertyAddress = Self.address(selector)
        guard CMIOObjectHasProperty(object, &propertyAddress) else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(object, &propertyAddress, 0, nil,
                                               UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
