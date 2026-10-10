//
//  CameraPreview.swift
//  iCam (iPhone)
//

import AVFoundation
import SwiftUI

/// Live preview of the capture session, kept upright with a rotation
/// coordinator. It stays in the view hierarchy for the app's lifetime so the
/// capture session is never reconfigured mid-stream by adding or removing a
/// preview connection.
struct CameraPreview: UIViewRepresentable {
    let camera: CameraCapture

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        camera.onDeviceChange = { [weak view] device in
            view?.attach(device: device)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        func attach(device: AVCaptureDevice?) {
            observation?.invalidate()
            observation = nil
            coordinator = nil
            guard let device else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            self.coordinator = coordinator
            observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                              options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async {
                    guard let connection = self?.previewLayer.connection,
                          connection.isVideoRotationAngleSupported(angle) else { return }
                    connection.videoRotationAngle = angle
                }
            }
        }
    }
}
