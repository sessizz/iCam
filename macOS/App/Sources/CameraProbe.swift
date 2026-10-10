//
//  CameraProbe.swift
//  iCam (Mac)
//
//  Tells apart the two reasons iCam may not see its own virtual camera:
//
//   * Only this process has a stale device list (macOS doesn't show a camera
//     extension to a process that was running when the extension was
//     activated or updated). A relaunch fixes it.
//   * macOS didn't start the updated extension at all, so no newly started
//     app sees the camera. Relaunching can't help; the user has to log out,
//     toggle the extension in System Settings, or restart.
//
//  The app runs its own executable with `--probe-camera`, which checks from a
//  fresh process whether the camera is visible and exits.
//

import AVFoundation
import Foundation

enum CameraProbe {
    static let argument = "--probe-camera"

    /// Entry point of the probe process: 0 if the camera is visible.
    static func runInProbeProcess() -> Int32 {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if isCameraVisible() { return 0 }
            // Give CoreMediaIO a moment to finish loading extension devices.
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return 1
    }

    static func isCameraVisible() -> Bool {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video,
                                                       position: .unspecified).devices
        let wanted = VirtualCamera.deviceUUID.uuidString
        return devices.contains {
            $0.uniqueID.caseInsensitiveCompare(wanted) == .orderedSame || $0.localizedName == VirtualCamera.deviceName
        }
    }

    /// Runs the probe in a new process. Calls back on the main queue with
    /// true/false, or nil if the probe couldn't run.
    static func probe(completion: @escaping @Sendable (Bool?) -> Void) {
        guard let executable = Bundle.main.executableURL else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = [argument]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            if finished.wait(timeout: .now() + 8) == .timedOut {
                process.terminate()
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let visible = process.terminationReason == .exit && process.terminationStatus == 0
            DispatchQueue.main.async { completion(visible) }
        }
    }
}
