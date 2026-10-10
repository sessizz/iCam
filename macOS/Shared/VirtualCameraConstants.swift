//
//  VirtualCameraConstants.swift
//  Shared between the Mac app and the camera extension.
//

import Foundation

enum VirtualCamera {
    /// Identity of the virtual camera device. Never change these once
    /// shipped: video apps remember the selected camera by this ID.
    static let deviceUUID = UUID(uuidString: "7A1C3E52-9B4D-4F86-A2E1-5C0D8B6F3A91")!
    static let sourceStreamUUID = UUID(uuidString: "0E4B7D29-6C35-4A18-9F0B-3D2E1A7C5B84")!
    static let sinkStreamUUID = UUID(uuidString: "B5F82C17-4D6A-4E93-8C21-7A0E9D3F6B52")!

    static let deviceName = "iCam iPhone Camera"
    static let manufacturer = "iCam"
    static let model = "iPhone Camera"

    static let width = 1920
    static let height = 1080
    static let frameRate = 30

    /// Number of sample buffers the app may queue for the extension.
    static let sinkQueueSize: UInt32 = 3

    /// Custom CoreMediaIO properties on the *sink* stream.
    ///
    /// `demand` (read by the app): "1" while at least one video app is
    /// reading the camera, "0" otherwise. The app uses it to switch the
    /// iPhone's camera on and off, just like Continuity Camera.
    static let demandSelector = "iCdm"
    /// `message` (written by the app): text shown on the placeholder frame
    /// while no live video is available.
    static let messageSelector = "iCms"

    /// Darwin notifications posted by the extension as a second, independent
    /// demand channel (plus a heartbeat while in use), in case the custom
    /// property can't be read.
    static let demandOnNotification = "app.icam.virtualcamera.demand.on"
    static let demandOffNotification = "app.icam.virtualcamera.demand.off"

    static func extensionPropertyName(_ selector: String) -> String {
        "4cc_\(selector)_glob_0000"
    }

    static func fourCharCode(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
