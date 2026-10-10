//
//  WelcomeView.swift
//  iCam (Mac)
//

import SwiftUI

struct WelcomeView: View {
    let model: AppModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "web.camera.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use your iPhone as a webcam")
                        .font(.title2.weight(.semibold))
                    Text("iCam works with FaceTime, Zoom, Teams, Meet, Photo Booth, OBS and every other camera app.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                Step(number: 1, title: "Allow the camera extension", done: model.extensionManager.status == .active) {
                    extensionDetail
                }
                Step(number: 2, title: "Open iCam on your iPhone", done: model.devices.connected != nil) {
                    Text("Install the iCam app on your iPhone and keep it open. Allow camera access when asked.")
                }
                Step(number: 3, title: "Connect", done: model.devices.connected != nil) {
                    Text("Plug in a USB cable for the lowest latency (tap “Trust” on the iPhone the first time), or use the same Wi-Fi network. iCam connects automatically.")
                }
                Step(number: 4, title: "Pick “\(VirtualCamera.deviceName)”", done: model.cameraInUse) {
                    Text("Choose it as the camera in any app. The iPhone camera turns on automatically while it's in use and off when you're done.")
                }
            }

            HStack {
                Text("iCam lives in the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    @ViewBuilder
    private var extensionDetail: some View {
        switch model.extensionManager.status {
        case .active:
            Text("The iCam camera is installed.")
        case .unknown, .installing:
            Text("Installing…")
        case .needsApproval:
            VStack(alignment: .leading, spacing: 8) {
                Text("macOS needs your permission to add the iCam camera. Open System Settings › General › Login Items & Extensions › Camera Extensions (or Privacy & Security on older macOS) and turn on iCam.")
                Button("Open System Settings") { model.extensionManager.openApprovalSettings() }
            }
        case .rebootRequired:
            Text("Restart your Mac to finish the installation.")
        case .notInApplications:
            Text("Move iCam to the Applications folder and open it from there. macOS only installs camera extensions from apps in Applications.")
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: reason)
                Button("Try Again") { model.extensionManager.activate() }
            }
        }
    }
}

private struct Step<Detail: View>: View {
    let number: Int
    let title: LocalizedStringKey
    let done: Bool
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.callout.weight(.semibold))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                detail()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
