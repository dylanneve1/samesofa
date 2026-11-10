import AVFoundation
import Foundation
import SameSofaCore
import WebRTC

/// Network settings for the peer connection.
public struct IceSettings: Codable, Equatable, Sendable {
    public var stunURLs: [String]
    public var turnURL: String
    public var turnUsername: String
    public var turnCredential: String

    public static let defaultSTUN = ["stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478"]

    public init(stunURLs: [String] = IceSettings.defaultSTUN, turnURL: String = "", turnUsername: String = "", turnCredential: String = "") {
        self.stunURLs = stunURLs
        self.turnURL = turnURL
        self.turnUsername = turnUsername
        self.turnCredential = turnCredential
    }

    var rtcServers: [RTCIceServer] {
        var servers: [RTCIceServer] = []
        let stun = stunURLs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !stun.isEmpty { servers.append(RTCIceServer(urlStrings: stun)) }
        let turn = turnURL.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !turn.isEmpty {
            servers.append(RTCIceServer(urlStrings: turn, username: turnUsername, credential: turnCredential))
        }
        return servers
    }
}

/// Where the camera picture comes from.
public enum CameraSource: Sendable {
    case camera
    /// A generated picture, for tests and screenshots (no real camera).
    case synthetic(label: String, hue: Double)
    case none
}

public protocol CallSessionDelegate: AnyObject {
    func call(_ call: CallSession, wantsToSignal payload: [String: Any])
    func call(_ call: CallSession, connectionChanged connected: Bool)
    func call(_ call: CallSession, controlChannelOpened channel: RTCDataChannel)
    func call(_ call: CallSession, fileChannelOpened channel: RTCDataChannel)
    func call(_ call: CallSession, remoteVideoTrack track: RTCVideoTrack)
}

/// One WebRTC peer connection: camera + microphone both ways and two data
/// channels ("control" for small JSON messages, "file" for the film's bytes).
/// The host makes the offer and creates the data channels.
public final class CallSession: NSObject, RTCPeerConnectionDelegate {
    public weak var delegate: CallSessionDelegate?
    public let role: PeerRole
    public let audio: AudioHub
    private let factory: RTCPeerConnectionFactory
    private var pc: RTCPeerConnection?
    public private(set) var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var videoSource: RTCVideoSource?
    private var cameraCapturer: RTCCameraVideoCapturer?
    private var syntheticCapturer: SyntheticCapturer?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false
    private let cameraSource: CameraSource
    public private(set) var cameraOn = true

    public init(role: PeerRole, audio: AudioHub, ice: IceSettings, camera: CameraSource) {
        self.role = role
        self.audio = audio
        self.cameraSource = camera
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                           decoderFactory: RTCDefaultVideoDecoderFactory(),
                                           audioDevice: audio)
        super.init()

        let config = RTCConfiguration()
        config.iceServers = ice.rtcServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        addLocalMedia()
        if role == .host { createDataChannels() }
    }

    // MARK: Local media

    private func addLocalMedia() {
        guard let pc else { return }
        // SameSofa cleans the microphone itself (AudioHub: echo cancellation
        // that also knows about the film, noise suppression, gain control);
        // WebRTC's own processing, which only knows the voice, stays off.
        let processing: [String: String] = [
            "googEchoCancellation": "false", "googAutoGainControl": "false", "googNoiseSuppression": "false", "googHighpassFilter": "false",
        ]
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: processing, optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "mic")
        pc.add(audioTrack, streamIds: ["samesofa"])
        localAudioTrack = audioTrack

        let source = factory.videoSource()
        videoSource = source
        let videoTrack = factory.videoTrack(with: source, trackId: "cam")
        localVideoTrack = videoTrack
        if let sender = pc.add(videoTrack, streamIds: ["samesofa"]) {
            // Keep the camera modest so the film transfer gets most of the uplink.
            let params = sender.parameters
            for encoding in params.encodings { encoding.maxBitrateBps = 700_000; encoding.maxFramerate = 30 }
            sender.parameters = params
        }
        startCamera()
    }

    public func startCamera() {
        guard let source = videoSource else { return }
        switch cameraSource {
        case .none:
            break
        case .synthetic(let label, let hue):
            let capturer = SyntheticCapturer(delegate: source, label: label, hue: hue)
            capturer.start()
            syntheticCapturer = capturer
        case .camera:
            guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front }) ?? RTCCameraVideoCapturer.captureDevices().first else { return }
            let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
            // Closest to 640x480 keeps encode cheap and bandwidth low.
            let format = formats.min(by: { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return abs(Int(da.width) - 640) + abs(Int(da.height) - 480) < abs(Int(db.width) - 640) + abs(Int(db.height) - 480)
            })
            guard let format else { return }
            let fps = min(30, format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
            let capturer = RTCCameraVideoCapturer(delegate: source)
            capturer.startCapture(with: device, format: format, fps: Int(fps))
            cameraCapturer = capturer
        }
        cameraOn = true
        localVideoTrack?.isEnabled = true
    }

    public func stopCamera() {
        cameraCapturer?.stopCapture()
        cameraCapturer = nil
        syntheticCapturer?.stop()
        syntheticCapturer = nil
        cameraOn = false
        localVideoTrack?.isEnabled = false
    }

    public func setMicMuted(_ muted: Bool) {
        audio.micMuted = muted
        localAudioTrack?.isEnabled = !muted
    }

    // MARK: Data channels

    private func createDataChannels() {
        guard let pc else { return }
        let control = RTCDataChannelConfiguration()
        control.isOrdered = true
        if let channel = pc.dataChannel(forLabel: "control", configuration: control) {
            ChannelRelay.install(on: channel)
            pendingChannels.append(channel)
        }
        let file = RTCDataChannelConfiguration()
        file.isOrdered = true
        if let channel = pc.dataChannel(forLabel: "file", configuration: file) {
            ChannelRelay.install(on: channel)
            pendingChannels.append(channel)
        }
    }

    /// Host-created channels, handed to the delegate once it is set.
    private var pendingChannels: [RTCDataChannel] = []

    public func announceChannels() {
        for channel in pendingChannels { hand(channel) }
        pendingChannels.removeAll()
    }

    private func hand(_ channel: RTCDataChannel) {
        if channel.label == "control" { delegate?.call(self, controlChannelOpened: channel) }
        if channel.label == "file" { delegate?.call(self, fileChannelOpened: channel) }
    }

    // MARK: Negotiation

    public func makeOffer() {
        guard let pc else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self, let sdp, error == nil else { return }
            pc.setLocalDescription(sdp) { _ in }
            DispatchQueue.main.async {
                self.delegate?.call(self, wantsToSignal: ["sdp": sdp.sdp, "kind": "offer"])
            }
        }
    }

    public func handleSignal(_ payload: [String: Any]) {
        guard let pc else { return }
        if let sdpText = payload["sdp"] as? String, let kind = payload["kind"] as? String {
            let type: RTCSdpType = kind == "offer" ? .offer : .answer
            pc.setRemoteDescription(RTCSessionDescription(type: type, sdp: sdpText)) { [weak self] error in
                guard let self, error == nil else { return }
                DispatchQueue.main.async {
                    self.hasRemoteDescription = true
                    for c in self.pendingCandidates { pc.add(c) { _ in } }
                    self.pendingCandidates.removeAll()
                    if type == .offer { self.makeAnswer() }
                }
            }
        } else if let candidate = payload["candidate"] as? String {
            let c = RTCIceCandidate(sdp: candidate,
                                    sdpMLineIndex: Int32(payload["mline"] as? Int ?? 0),
                                    sdpMid: payload["mid"] as? String)
            if hasRemoteDescription { pc.add(c) { _ in } } else { pendingCandidates.append(c) }
        }
    }

    private func makeAnswer() {
        guard let pc else { return }
        pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, error in
            guard let self, let sdp, error == nil else { return }
            pc.setLocalDescription(sdp) { _ in }
            DispatchQueue.main.async {
                self.delegate?.call(self, wantsToSignal: ["sdp": sdp.sdp, "kind": "answer"])
            }
        }
    }

    public func close() {
        stopCamera()
        pc?.close()
        pc = nil
    }

    // MARK: RTCPeerConnectionDelegate (called on WebRTC's signalling thread)

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        DispatchQueue.main.async {
            switch newState {
            case .connected: self.delegate?.call(self, connectionChanged: true)
            case .failed, .disconnected, .closed: self.delegate?.call(self, connectionChanged: false)
            default: break
            }
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let payload: [String: Any] = ["candidate": candidate.sdp, "mline": Int(candidate.sdpMLineIndex), "mid": candidate.sdpMid ?? ""]
        DispatchQueue.main.async { self.delegate?.call(self, wantsToSignal: payload) }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        ChannelRelay.install(on: dataChannel)
        DispatchQueue.main.async { self.hand(dataChannel) }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            DispatchQueue.main.async { self.delegate?.call(self, remoteVideoTrack: track) }
        }
    }
}
