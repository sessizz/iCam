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

    @ObservationIgnored private let log = Logger(subsystem: "app.icam.mac", category: "extension")

    var extensionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "app.icam.mac") + ".CameraExtension"
    }

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
        // Always install the copy bundled with this app so the extension and
        // the app speak the same protocol.
        .replace
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
