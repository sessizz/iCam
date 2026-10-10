//
//  ExtensionManager.swift
//  iCam (Mac)
//
//  Installs / updates the bundled camera system extension.
//

import AppKit
import Observation
import SystemExtensions
import os

@MainActor
@Observable
final class ExtensionManager: NSObject {

    enum Status: Equatable {
        case unknown
        case installing
        case needsApproval
        case active
        case rebootRequired
        case notInApplications
        case failed(String)
    }

    private(set) var status: Status = .unknown

    /// What `systemextensionsctl list` reports for the iCam extension, one
    /// entry per installed copy, e.g. "1.0/1791621540 [activated enabled]".
    private(set) var systemRecords: [String] = []

    /// The bundled extension replaced an installed copy while this process
    /// was running.
    private(set) var replacedDuringThisRun = false
    /// The latest activation kept an installed copy of the same version.
    @ObservationIgnored private var keptSameVersion = false

    @ObservationIgnored private let log = Logger(subsystem: "app.icam.mac", category: "extension")

    var extensionIdentifier: String { Self.extensionIdentifier }

    private nonisolated static var extensionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "app.icam.mac") + ".CameraExtension"
    }

    /// Version (CFBundleVersion) of the extension bundled with this app, nil
    /// if it can't be read.
    let bundledVersion: String? = {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\(ExtensionManager.extensionIdentifier).systemextension")
        return Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String
    }()

    var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Activates the extension. If the same version is already active this
    /// completes immediately; a newer bundled version replaces the old one.
    func activate() {
        guard isInApplicationsFolder else {
            status = .notInApplications
            return
        }
        if status != .active { status = .installing }
        keptSameVersion = false
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier,
                                                                 queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        log.info("Submitted activation request for \(self.extensionIdentifier, privacy: .public)")
    }

    func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier,
                                                                   queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Re-reads `systemextensionsctl list` in the background.
    func refreshSystemRecords() {
        let identifier = extensionIdentifier
        Task.detached(priority: .utility) {
            let records = Self.readSystemRecords(identifier: identifier)
            await MainActor.run { self.systemRecords = records }
        }
    }

    private nonisolated static func readSystemRecords(identifier: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ["systemextensionsctl failed: \(error.localizedDescription)"]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Lines look like:
        // *  *  TEAMID  com.x.icam.mac.CameraExtension (1.0/1791621540)  iCam Camera  [activated enabled]
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { $0.contains(identifier) }
            .map { line in
                let version = line.range(of: #"\([^)]*\)"#, options: .regularExpression)
                    .map { String(line[$0].dropFirst().dropLast()) } ?? "?"
                let state = line.range(of: #"\[[^\]]*\]"#, options: .regularExpression)
                    .map { String(line[$0]) } ?? "?"
                return "\(version) \(state)"
            }
    }

    func openApprovalSettings() {
        let candidates: [String]
        if #available(macOS 15, *) {
            candidates = ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                          "x-apple.systempreferences:com.apple.ExtensionsPreferences"]
        } else {
            candidates = ["x-apple.systempreferences:com.apple.preference.security?General",
                          "x-apple.systempreferences:com.apple.preference.security"]
        }
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    fileprivate func handle(result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            status = .active
            log.info("Camera extension active")
            refreshSystemRecords()
        case .willCompleteAfterReboot:
            status = .rebootRequired
        @unknown default:
            status = .active
        }
    }

    fileprivate func handle(error: Error) {
        let nsError = error as NSError
        log.error("Extension request failed: \(nsError, privacy: .public)")
        if nsError.domain == OSSystemExtensionErrorDomain,
           let code = OSSystemExtensionError.Code(rawValue: nsError.code) {
            switch code {
            case .unsupportedParentBundleLocation:
                status = .notInApplications
                return
            case .requestSuperseded:
                return
            case .requestCanceled where keptSameVersion:
                status = .active
                log.info("Camera extension already active")
                refreshSystemRecords()
                return
            case .authorizationRequired:
                status = .needsApproval
                return
            default:
                break
            }
        }
        status = .failed(nsError.localizedDescription)
    }
}

extension ExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction {
        // Same version: macOS asks anyway when System Extension developer
        // mode is on. Keep the running copy; replacing it only disrupts apps
        // using the camera (and macOS sometimes fails to start the new one).
        if existing.bundleVersion == ext.bundleVersion,
           existing.bundleShortVersion == ext.bundleShortVersion {
            MainActor.assumeIsolated { self.keptSameVersion = true }
            return .cancel
        }
        // Otherwise install the copy bundled with this app so the extension
        // and the app speak the same protocol.
        let from = existing.bundleVersion
        let to = ext.bundleVersion
        MainActor.assumeIsolated {
            self.replacedDuringThisRun = true
            self.log.notice("Replacing camera extension \(from, privacy: .public) with \(to, privacy: .public)")
        }
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { self.status = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated { self.handle(result: result) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.handle(error: error) }
    }
}
