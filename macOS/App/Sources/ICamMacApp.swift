//
//  ICamMacApp.swift
//  iCam (Mac)
//
//  Menu bar app: receives the iPhone's camera and feeds the iCam virtual
//  camera. Runs in the background (no Dock icon) and starts at login.
//

import AppKit
import SwiftUI

@main
struct ICamMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: appDelegate.model) {
                appDelegate.showWelcome()
            }
        } label: {
            MenuBarIcon(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIcon: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.cameraInUse ? "web.camera.fill" : "web.camera")
            .accessibilityLabel("iCam")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var welcomeWindow: NSWindow?
    private var statusObservation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        observeExtensionStatus()

        // Give the activation request a moment to report before deciding
        // whether the user needs the setup guide.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.model.needsOnboarding else { return }
            self.showWelcome()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launched again from Finder/Launchpad while running: show the guide
        // so the app never seems to "do nothing".
        showWelcome()
        return false
    }

    func showWelcome() {
        if welcomeWindow == nil {
            let hosting = NSHostingController(rootView: WelcomeView(model: model) { [weak self] in
                self?.welcomeWindow?.close()
            })
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "Welcome to iCam")
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            welcomeWindow = window
        }
        model.markWelcomeShown()
        NSApp.activate()
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    private func observeExtensionStatus() {
        // Re-scan for the virtual camera once the extension becomes active.
        statusObservation = Task { [weak self] in
            var lastStatus: ExtensionManager.Status?
            while !Task.isCancelled {
                guard let self else { return }
                let status = self.model.extensionManager.status
                if status != lastStatus {
                    if status == .active { self.model.extensionBecameActive() }
                    lastStatus = status
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
