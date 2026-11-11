import AppKit
import AVFoundation
import SameSofaCore
import SwiftUI
import WebRTC

/// The film. A plain AVPlayerLayer: SameSofa draws its own controls.
///
/// The layer is opaque, pixel-aligned and at the display's own scale, so the
/// system scales the picture once, at full quality and bit depth (10-bit and
/// HDR are handled by AVPlayerLayer itself). While the film plays, a display
/// link asks a variable-refresh display (ProMotion, adaptive sync) to refresh
/// at a whole multiple of the film's frame rate, so every frame is shown for
/// the same time; on a display with a fixed refresh rate this has no effect.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var frameRate: Double = 0
    var playing = false
    var matchFrameRate = true

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.setPacing(frameRate: matchFrameRate && playing ? frameRate : 0)
    }

    static func dismantleNSView(_ view: PlayerNSView, coordinator: ()) {
        view.setPacing(frameRate: 0)
    }

    final class PlayerNSView: NSView {
        /// The film's view, for whoever has to know whether the picture is really being shown.
        static weak var current: PlayerNSView?
        let playerLayer = AVPlayerLayer()
        private var displayLink: CADisplayLink?
        private var pacedFrameRate = 0.0
        /// What the display link was last asked for (Hz), for the quality readout.
        private(set) var requestedRefreshRate: Double?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.isOpaque = true
            playerLayer.videoGravity = .resizeAspect
            playerLayer.isOpaque = true
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Whole device pixels, at the screen's scale: no blurry half-pixel edges.
            playerLayer.frame = backingAlignedRect(bounds, options: .alignAllEdgesNearest)
            playerLayer.contentsScale = window?.backingScaleFactor ?? 2
            CATransaction.commit()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            needsLayout = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { PlayerNSView.current = self }
            let rate = pacedFrameRate
            pacedFrameRate = 0
            setPacing(frameRate: rate)
        }

        /// `frameRate` 0: no preference (paused, or matching switched off).
        func setPacing(frameRate: Double) {
            guard frameRate != pacedFrameRate || (frameRate > 0 && displayLink == nil) else { return }
            pacedFrameRate = frameRate
            displayLink?.invalidate()
            displayLink = nil
            requestedRefreshRate = nil
            guard frameRate >= 1, let screen = window?.screen,
                  let refresh = FrameRateMatch.preferredRefreshRate(filmFrameRate: frameRate, displayMaximum: Double(screen.maximumFramesPerSecond)) else { return }
            let link = displayLink(target: self, selector: #selector(refreshed(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(refresh), maximum: Float(refresh), preferred: Float(refresh))
            link.add(to: .main, forMode: .common)
            displayLink = link
            requestedRefreshRate = refresh
        }

        /// Nothing to draw: the link only tells the system which refresh rate suits the film.
        @objc private func refreshed(_ link: CADisplayLink) {}
    }
}

/// A WebRTC video track, drawn with Metal, clipped to rounded corners.
struct RTCVideoSurface: NSViewRepresentable {
    let track: RTCVideoTrack?
    var cornerRadius: CGFloat = 16
    var mirrored = false
    /// Told the size of the picture whenever it changes (the view stretches the picture to its own
    /// bounds, so whoever lays it out at full size gives it the picture's shape).
    var onVideoSize: ((CGSize) -> Void)?

    func makeNSView(context: Context) -> Container {
        Container(cornerRadius: cornerRadius, mirrored: mirrored)
    }

    func updateNSView(_ view: Container, context: Context) {
        view.layer?.cornerRadius = cornerRadius
        view.onVideoSize = onVideoSize
        view.setTrack(track)
    }

    static func dismantleNSView(_ view: Container, coordinator: ()) {
        view.setTrack(nil)
    }

    final class Container: NSView, RTCVideoViewDelegate {
        private let video = RTCMTLNSVideoView(frame: .zero)
        private weak var track: RTCVideoTrack?
        var onVideoSize: ((CGSize) -> Void)?

        func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            DispatchQueue.main.async { self.onVideoSize?(size) }
        }

        init(cornerRadius: CGFloat, mirrored: Bool) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
            video.wantsLayer = true
            video.delegate = self
            addSubview(video)
            if mirrored {
                // Self-view is mirrored, like every video call.
                video.layer?.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        func setTrack(_ newTrack: RTCVideoTrack?) {
            guard newTrack !== track else { return }
            track?.remove(video)
            track = newTrack
            newTrack?.add(video)
        }

        override func layout() {
            super.layout()
            video.frame = bounds
            if let layer = video.layer, layer.affineTransform() != .identity {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            }
        }
    }
}

/// Hides the mouse pointer while the controls are hidden (full-screen viewing).
struct CursorHider: NSViewRepresentable {
    let hidden: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        if hidden { NSCursor.setHiddenUntilMouseMoves(true) }
    }
}
