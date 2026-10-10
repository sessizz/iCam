//
//  PlaceholderRenderer.swift
//  iCam Camera Extension
//
//  Draws the frame shown while no live iPhone video is available.
//

import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import VideoToolbox

final class PlaceholderRenderer {
    private var transferSession: VTPixelTransferSession?

    init() {
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession)
    }

    deinit {
        if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
    }

    /// Renders `message` into a new 420v pixel buffer of the given size.
    func render(message: String, width: Int, height: Int) -> CVPixelBuffer? {
        guard let bgra = makeBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA),
              let output = makeBuffer(width: width, height: height,
                                      format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) else {
            return nil
        }
        draw(message: message, into: bgra)

        CVBufferSetAttachment(bgra, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(bgra, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        guard let transferSession,
              VTPixelTransferSessionTransferImage(transferSession, from: bgra, to: output) == noErr else {
            return nil
        }
        return output
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        return buffer
    }

    private func draw(message: String, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

        let w = CGFloat(width)
        let h = CGFloat(height)
        let scale = h / 1080

        // Background: subtle vertical gradient.
        let colors = [CGColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1),
                      CGColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        }

        // Camera glyph: rounded body + lens + viewfinder bump.
        let glyphWidth = 150 * scale
        let glyphHeight = 104 * scale
        let center = CGPoint(x: w / 2, y: h / 2 + 90 * scale)
        let body = CGRect(x: center.x - glyphWidth / 2, y: center.y - glyphHeight / 2,
                          width: glyphWidth, height: glyphHeight)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
        context.addPath(CGPath(roundedRect: body, cornerWidth: 22 * scale, cornerHeight: 22 * scale, transform: nil))
        context.fillPath()
        let bump = CGRect(x: center.x - 30 * scale, y: body.maxY - 4 * scale, width: 60 * scale, height: 20 * scale)
        context.addPath(CGPath(roundedRect: bump, cornerWidth: 8 * scale, cornerHeight: 8 * scale, transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(srgbRed: 0.07, green: 0.08, blue: 0.09, alpha: 1))
        context.fillEllipse(in: CGRect(x: center.x - 32 * scale, y: center.y - 32 * scale,
                                       width: 64 * scale, height: 64 * scale))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
        context.fillEllipse(in: CGRect(x: center.x - 20 * scale, y: center.y - 20 * scale,
                                       width: 40 * scale, height: 40 * scale))

        drawText("iCam", size: 44 * scale, emphasized: true, alpha: 0.9,
                 centerY: h / 2 - 40 * scale, width: w, in: context)
        drawText(message, size: 30 * scale, emphasized: false, alpha: 0.55,
                 centerY: h / 2 - 105 * scale, width: w, in: context)
    }

    private func drawText(_ text: String, size: CGFloat, emphasized: Bool, alpha: CGFloat,
                          centerY: CGFloat, width: CGFloat, in context: CGContext) {
        guard let font = CTFontCreateUIFontForLanguage(emphasized ? .emphasizedSystem : .system, size, nil) else {
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

        var drawnLine = line
        let maxWidth = width * 0.86
        if lineWidth > maxWidth {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            if let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) {
                drawnLine = truncated
                lineWidth = CGFloat(CTLineGetTypographicBounds(truncated, &ascent, &descent, nil))
            }
        }
        context.textPosition = CGPoint(x: (width - lineWidth) / 2, y: centerY - (ascent - descent) / 2)
        CTLineDraw(drawnLine, context)
    }
}
