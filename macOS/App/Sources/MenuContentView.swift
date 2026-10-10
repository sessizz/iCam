//
//  MenuContentView.swift
//  iCam (Mac)
//

import SwiftUI

struct MenuContentView: View {
    let model: AppModel
    var openWelcome: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            previewSection
            ExtensionBanner(model: model, openWelcome: openWelcome)
            PhoneList(devices: model.devices)
            if model.devices.connected != nil, let status = model.devices.phoneStatus {
                Divider()
                CameraControls(model: model, status: status)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(WindowVisibilityReader { visible in model.setPreviewVisible(visible) })
        .onDisappear { model.setPreviewVisible(false) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "web.camera.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("iCam")
                .font(.headline)
            Spacer()
            StatusPill(model: model)
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black)
            if model.devices.connected != nil {
                PreviewView(feed: model.preview)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if model.stats.fps == 0 {
                VStack(spacing: 6) {
                    Image(systemName: model.devices.connected == nil ? "iphone.slash" : "video")
                        .font(.title2)
                    Text(previewPlaceholder)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .foregroundStyle(.white.opacity(0.6))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .bottomLeading) {
            if model.stats.fps > 0 {
                Text(statsText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
    }

    private var previewPlaceholder: LocalizedStringKey {
        switch model.devices.state {
        case .connected: return "Starting camera…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .searching: return "Open iCam on your iPhone. Connect it with a cable or join the same Wi-Fi."
        }
    }

    private var statsText: String {
        let stats = model.stats
        var parts = [String(format: "%.0f fps", stats.fps),
                     String(format: "%.1f Mbps", stats.bitrate / 1_000_000)]
        if stats.rttMs > 0 { parts.append(String(format: "%.0f ms", stats.rttMs)) }
        if let codec = stats.codec { parts.append(codec.displayName) }
        if stats.width > 0 { parts.append("\(stats.width)×\(stats.height)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Video codec", selection: Binding(get: { model.codec }, set: { model.setCodec($0) })) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }
                    Picker("Portrait iPhone", selection: Binding(get: { model.framing },
                                                                   set: { model.setFraming($0) })) {
                        Text("Fill frame").tag(PortraitFraming.fill)
                        Text("Show all").tag(PortraitFraming.fit)
                    }
                    Button("Setup Guide…", action: openWelcome)
                        .buttonStyle(.link)
                }
                .padding(.top, 6)
            }
            .font(.callout)

            DisclosureGroup("Diagnostics") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: model.diagnosticsReport)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy Diagnostics") { model.copyDiagnostics() }
                        .buttonStyle(.link)
                }
                .padding(.top, 6)
            }
            .font(.callout)

            HStack {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                        set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quit iCam") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.callout)
        }
    }
}

// MARK: - Status pill

private struct StatusPill: View {
    let model: AppModel

    var body: some View {
        let (text, color) = content
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private var content: (LocalizedStringKey, Color) {
        if model.cameraInUse && model.stats.fps > 0 { return ("Live", .red) }
        switch model.devices.state {
        case .connected: return (model.cameraInUse ? "Starting" : "Ready", .green)
        case .connecting: return ("Connecting", .orange)
        case .searching: return ("Searching", .secondary)
        }
    }
}

// MARK: - Extension banner

private struct ExtensionBanner: View {
    let model: AppModel
    var openWelcome: () -> Void

    var body: some View {
        switch model.extensionManager.status {
        case .active:
            if model.cameraAccess == .denied || model.cameraAccess == .restricted {
                banner(icon: "video.slash.fill", color: .orange,
                       text: Text("Allow camera access for iCam so it can feed the virtual camera.")) {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } else if model.cameraMissing || model.extensionOutdated {
                banner(icon: "exclamationmark.triangle.fill", color: .orange, text: missingCameraText) {
                    Button("Reopen iCam") { model.relaunch() }
                }
            } else if case .failed(let reason) = model.sinkState {
                banner(icon: "exclamationmark.triangle.fill", color: .orange, text: Text(verbatim: reason)) {
                    Button("Retry") { model.extensionBecameActive() }
                }
            }
        case .unknown, .installing:
            banner(icon: "arrow.down.circle", color: .secondary, text: Text("Installing camera extension…")) {
                EmptyView()
            }
        case .needsApproval:
            banner(icon: "hand.raised.fill", color: .orange,
                   text: Text("Allow the iCam camera extension in System Settings.")) {
                Button("Open Settings") { model.extensionManager.openApprovalSettings() }
            }
        case .rebootRequired:
            banner(icon: "arrow.clockwise", color: .orange,
                   text: Text("Restart your Mac to finish installing the camera.")) { EmptyView() }
        case .notInApplications:
            banner(icon: "folder.fill", color: .orange,
                   text: Text("Move iCam to the Applications folder, then open it again.")) {
                Button("Help") { openWelcome() }
            }
        case .failed(let reason):
            banner(icon: "xmark.octagon.fill", color: .red, text: Text(verbatim: reason)) {
                Button("Retry") { model.extensionManager.activate() }
            }
        }
    }

    private var missingCameraText: Text {
        if model.extensionManager.hasOutgoingCopy || model.extensionOutdated {
            return Text("An older copy of the iCam camera is still in use. Quit apps that use the camera (OBS, Zoom, FaceTime…), then reopen iCam. If that doesn't help, restart your Mac.")
        }
        return Text("macOS hasn't made the iCam camera available to this app yet. Quit apps that use the camera (OBS, Zoom, FaceTime…), then reopen iCam. If that doesn't help, restart your Mac.")
    }

    private func banner<Accessory: View>(icon: String, color: Color, text: Text,
                                         @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            text.font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            accessory().controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
    }
}

// MARK: - Phones

private struct PhoneList: View {
    let devices: DeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("iPhone")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if devices.phones.isEmpty {
                Text("No iPhone found. Open iCam on your iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }

            ForEach(devices.phones) { phone in
                Button {
                    devices.select(phone)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone")
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(phone.name)
                            Text(detail(for: phone))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if phone.isConnected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(phone.isConnected ? Color.accentColor.opacity(0.12) : Color.clear))
                }
                .buttonStyle(.plain)
            }

            if let error = devices.lastError, devices.connected == nil {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let problem = devices.networkProblem {
                Label("Wi-Fi discovery unavailable: \(problem). Check Local Network access in System Settings › Privacy & Security.",
                      systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if devices.connected != nil {
                Button("Disconnect") { devices.disconnect() }
                    .buttonStyle(.link)
                    .font(.caption)
            } else if devices.isPaused, let first = devices.phones.first {
                Button("Reconnect") { devices.select(first) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func detail(for phone: PhoneEntry) -> String {
        var parts: [String] = []
        if phone.isConnected, let connected = devices.connected {
            parts.append(connected.transport == .usb
                         ? String(localized: "Connected via USB")
                         : String(localized: "Connected via Wi-Fi"))
            if let status = devices.phoneStatus, status.batteryLevel >= 0 {
                let percent = Int((status.batteryLevel * 100).rounded())
                parts.append(status.isCharging ? "\(percent)% ⚡︎" : "\(percent)%")
            }
            if let status = devices.phoneStatus, status.thermalState >= 2 {
                parts.append(String(localized: "Warm"))
            }
        } else {
            var transports: [String] = []
            if phone.hasUSB { transports.append("USB") }
            if phone.hasWiFi { transports.append("Wi-Fi") }
            parts.append(transports.joined(separator: " + "))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Camera controls

private struct CameraControls: View {
    let model: AppModel
    let status: PhoneStatus
    @State private var zoom: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !status.lenses.isEmpty {
                Picker("Camera", selection: Binding(get: { status.currentLensID ?? "" },
                                                    set: { model.selectLens($0) })) {
                    ForEach(status.lenses) { lens in
                        Text(lens.id == "front" ? String(localized: "Front") : lens.label)
                            .tag(lens.id)
                            .help(lens.name)
                    }
                }
                .pickerStyle(.segmented)
            }

            if let lens = status.lenses.first(where: { $0.id == status.currentLensID }), lens.maxZoom > 1 {
                HStack {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                    Slider(value: $zoom, in: 1...lens.maxZoom)
                        .onChange(of: zoom) { _, value in
                            if abs(value - status.zoom) > 0.01 { model.setZoom(value) }
                        }
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                }
            }

            HStack {
                Toggle("Mirror", isOn: Binding(get: { status.mirrored }, set: { model.setMirrored($0) }))
                Toggle("Stabilization", isOn: Binding(get: { status.stabilization },
                                                      set: { model.setStabilization($0) }))
            }
            .toggleStyle(.checkbox)
            .font(.callout)

            if status.isPortrait {
                Label("Turn your iPhone sideways for the best picture.", systemImage: "rotate.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let interruption = status.interruption {
                Label(interruption, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { zoom = status.zoom }
        .onChange(of: status.zoom) { _, value in
            if abs(value - zoom) > 0.01 { zoom = value }
        }
    }
}
