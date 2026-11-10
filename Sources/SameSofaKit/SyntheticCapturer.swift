import AppKit
import CoreVideo
import WebRTC

/// A stand-in camera that draws a soft gradient with a moving circle and a
/// label. Used by tests and for screenshots, so no real camera is involved.
final class SyntheticCapturer: RTCVideoCapturer {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "samesofa.synthetic.camera")
    private let label: String
    private let hue: Double
    private var frameIndex = 0
    private var pool: CVPixelBufferPool?
    let width = 640, height = 480

    init(delegate: RTCVideoCapturerDelegate, label: String, hue: Double) {
        self.label = label
        self.hue = hue
        super.init(delegate: delegate)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(66))
        timer.setEventHandler { [weak self] in self?.emit() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func emit() {
        guard let pool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb),
           let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            draw(in: ctx)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        frameIndex += 1
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pb), rotation: ._0,
                                  timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds))
        delegate?.capturer(self, didCapture: frame)
    }

    private func draw(in ctx: CGContext) {
        let w = CGFloat(width), h = CGFloat(height)
        let top = NSColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1).cgColor
        let bottom = NSColor(hue: fmod(hue + 0.08, 1), saturation: 0.6, brightness: 0.25, alpha: 1).cgColor
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        // A friendly abstract "head and shoulders" that sways gently.
        let t = Double(frameIndex) / 15
        let cx = w / 2 + CGFloat(sin(t * 0.7) * 18)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 70, y: h * 0.42, width: 140, height: 140))
        ctx.fillEllipse(in: CGRect(x: cx - 150, y: -h * 0.25, width: 300, height: 260))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.85),
        ]
        let text = NSAttributedString(string: label, attributes: attrs)
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(x: (w - bounds.width) / 2, y: 28)
        CTLineDraw(line, ctx)
    }
}
