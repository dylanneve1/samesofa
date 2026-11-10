import AppKit
import AVFoundation
import SwiftUI
import WebRTC

/// The film. A plain AVPlayerLayer: SameSofa draws its own controls.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// A WebRTC video track, drawn with Metal, clipped to rounded corners.
struct RTCVideoSurface: NSViewRepresentable {
    let track: RTCVideoTrack?
    var cornerRadius: CGFloat = 16
    var mirrored = false

    func makeNSView(context: Context) -> Container {
        Container(cornerRadius: cornerRadius, mirrored: mirrored)
    }

    func updateNSView(_ view: Container, context: Context) {
        view.layer?.cornerRadius = cornerRadius
        view.setTrack(track)
    }

    static func dismantleNSView(_ view: Container, coordinator: ()) {
        view.setTrack(nil)
    }

    final class Container: NSView {
        private let video = RTCMTLNSVideoView(frame: .zero)
        private weak var track: RTCVideoTrack?

        init(cornerRadius: CGFloat, mirrored: Bool) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
            video.wantsLayer = true
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
