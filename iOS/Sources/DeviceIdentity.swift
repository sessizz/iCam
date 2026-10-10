//
//  DeviceIdentity.swift
//  iCam (iPhone)
//

import UIKit

enum DeviceIdentity {
    private static let deviceIDKey = "deviceID"
    private static let deviceNameKey = "deviceName"

    /// Stable random identifier for this install. Lets the Mac recognise the
    /// same iPhone over USB and Wi-Fi.
    static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIDKey)
        return id
    }

    /// Name shown on the Mac. iOS no longer exposes the user-assigned device
    /// name to apps, so it is editable in Settings.
    static var deviceName: String {
        get {
            let stored = UserDefaults.standard.string(forKey: deviceNameKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty { return stored }
            return UIDevice.current.name
        }
        set {
            UserDefaults.standard.set(newValue, forKey: deviceNameKey)
        }
    }

    /// Hardware identifier, e.g. "iPhone16,1".
    static let modelIdentifier: String = {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "iPhone" : identifier
    }()
}
