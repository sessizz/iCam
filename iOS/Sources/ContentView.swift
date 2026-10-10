//
//  ContentView.swift
//  iCam (iPhone)
//

import SwiftUI

struct ContentView: View {
    @Bindable var model: PhoneModel
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Always mounted; see CameraPreview.
            CameraPreview(camera: model.pipeline.camera)
                .ignoresSafeArea()
                .opacity(model.isStreaming ? 1 : 0)

            if model.isStreaming {
                StreamingOverlay(model: model)
            } else {
                IdleView(model: model, showSettings: $showSettings)
            }

            if model.isDimmed {
                DimmedView(hostName: model.host?.hostName)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: model.isDimmed)
        .animation(.easeInOut(duration: 0.25), value: model.isStreaming)
        .contentShape(Rectangle())
        .onTapGesture { model.userInteracted() }
        .statusBarHidden(model.isStreaming)
        .persistentSystemOverlays(model.isStreaming ? .hidden : .automatic)
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
    }
}

// MARK: - Idle

private struct IdleView: View {
    let model: PhoneModel
    @Binding var showSettings: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                .accessibilityLabel("Settings")
            }
            Spacer()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(model.host == nil ? Color.white.opacity(0.08) : Color.green.opacity(0.18))
                        .frame(width: 120, height: 120)
                    Image(systemName: "web.camera.fill")
                        .font(.system(size: 50, weight: .medium))
                        .foregroundStyle(model.host == nil ? Color.white : Color.green)
                        .symbolEffect(.pulse, isActive: model.host == nil)
                }

                if let host = model.host {
                    VStack(spacing: 8) {
                        Text("Connected to \(host.hostName)")
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Label(host.transport.displayName,
                              systemImage: host.transport == .usb ? "cable.connector" : "wifi")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("The camera turns on automatically when an app on your Mac uses it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 6)
                    }
                } else {
                    VStack(spacing: 8) {
                        Text("Waiting for your Mac")
                            .font(.title2.weight(.semibold))
                        Text("Connect this iPhone with a cable or put it on the same Wi-Fi network, then open iCam on your Mac.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                if model.cameraAuthorization == .denied || model.cameraAuthorization == .restricted {
                    VStack(spacing: 10) {
                        Label("Camera access is off", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 520)

            Spacer()

            HStack(spacing: 18) {
                ListenerBadge(title: "USB", systemImage: "cable.connector", status: model.usbStatus)
                ListenerBadge(title: "Wi-Fi", systemImage: "wifi", status: model.wifiStatus)
            }
            .padding(.bottom, 8)

            Text("Advertised as “\(model.deviceName)”")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
    }
}

private struct ListenerBadge: View {
    let title: LocalizedStringKey
    let systemImage: String
    let status: ListenerStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    private var color: Color {
        switch status {
        case .ready: return .green
        case .starting: return .gray
        case .waiting: return .yellow
        case .failed: return .red
        }
    }

    private var accessibilityValue: Text {
        switch status {
        case .ready: return Text("Ready")
        case .starting: return Text("Starting")
        case .waiting(let reason), .failed(let reason): return Text(reason)
        }
    }
}

// MARK: - Streaming

private struct StreamingOverlay: View {
    let model: PhoneModel

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text("LIVE")
                    .font(.caption.weight(.bold))
                if let host = model.host {
                    Text("\(host.hostName) · \(host.transport.displayName)")
                        .font(.caption)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(statsText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal)
            .padding(.top, 8)

            if model.camera.isPortrait {
                Label("Turn iPhone sideways for the best picture", systemImage: "rotate.right")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if let interruption = model.camera.interruption {
                Label(interruption, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            LensPicker(model: model)
                .padding(.bottom, 20)
        }
    }

    private var statsText: String {
        let stats = model.stats
        guard stats.fps > 0 else { return "" }
        return String(format: "%.0f fps · %.1f Mbps · %.0f ms", stats.fps,
                      Double(stats.bitrate) / 1_000_000, stats.latencyMs)
    }
}

private struct LensPicker: View {
    let model: PhoneModel

    var body: some View {
        HStack(spacing: 10) {
            ForEach(model.camera.lenses) { lens in
                let selected = lens.id == model.camera.currentLensID
                Button {
                    model.selectLens(lens.id)
                    model.userInteracted()
                } label: {
                    Group {
                        if lens.id == CameraCapture.lensFront {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                        } else {
                            Text(lens.label)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(selected ? Color.yellow : Color.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(selected ? 0.6 : 0.35)))
                }
                .accessibilityLabel(lens.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(6)
        .background(Capsule().fill(Color.black.opacity(0.25)))
    }
}

// MARK: - Dimmed

private struct DimmedView: View {
    let hostName: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                Image(systemName: "web.camera")
                    .font(.title)
                    .foregroundStyle(.green.opacity(0.7))
                if let hostName {
                    Text("Streaming to \(hostName)")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text("Tap to show preview")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    let model: PhoneModel
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("iPhone", text: $name)
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: {
                    Text("Name shown on your Mac")
                }

                Section("Tips") {
                    Label("A USB cable gives the lowest latency and keeps your iPhone charged.",
                          systemImage: "cable.connector")
                    Label("Use the rear camera in landscape for the best picture.",
                          systemImage: "camera.rotate")
                    Label("Keep iCam open. The screen dims automatically while streaming.",
                          systemImage: "moon.fill")
                    Label("Over Wi-Fi, allow Local Network access when asked.",
                          systemImage: "wifi")
                }
                .font(.callout)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
            .onAppear { name = model.deviceName }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != model.deviceName {
            model.rename(to: trimmed)
        }
    }
}
