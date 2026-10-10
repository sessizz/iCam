//
//  PreviewFeed.swift
//  iCam (Mac)
//
//  Live preview in the menu bar panel.
//

import AVFoundation
import SwiftUI
import os

final class PreviewFeed {
    private let state = OSAllocatedUnfairLock<(active: Bool, layer: AVSampleBufferDisplayLayer?)>(
        initialState: (false, nil))

    var isActive: Bool {
        get { state.withLock { $0.active } }
        set {
            let layer = state.withLock { s -> AVSampleBufferDisplayLayer? in
                s.active = newValue
                return s.layer
            }
            if !newValue {
                DispatchQueue.main.async { layer?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
            }
        }
    }

    func attach(_ layer: AVSampleBufferDisplayLayer?) {
        state.withLock { $0.layer = layer }
    }

    /// Called on the video pipeline queue.
    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard let layer = state.withLock({ $0.active ? $0.layer : nil }) else { return }

        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &description)
        guard let description else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: description, sampleTiming: &timing,
                                                 sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sampleBuffer)
        }
    }
}

struct PreviewView: NSViewRepresentable {
    let feed: PreviewFeed

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        feed.attach(view.displayLayer)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}

    static func dismantleNSView(_ nsView: PreviewNSView, coordinator: ()) {
        nsView.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    final class PreviewNSView: NSView {
        let displayLayer = AVSampleBufferDisplayLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            displayLayer.videoGravity = .resizeAspect
            displayLayer.frame = bounds
            displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(displayLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
    }
}
