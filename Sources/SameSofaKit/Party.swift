import AVFoundation
import Combine
import Foundation
import SameSofaCore
import WebRTC

public struct PartySettings {
    public var serverURL: URL
    public var ice: IceSettings
    public var audioMode: AudioMode
    public var camera: CameraSource

    public init(serverURL: URL, ice: IceSettings = IceSettings(), audioMode: AudioMode = .voiceProcessing, camera: CameraSource = .camera) {
        self.serverURL = serverURL
        self.ice = ice
        self.audioMode = audioMode
        self.camera = camera
    }
}

/// One movie night: the room, the call, the film transfer and the shared
/// playback. Everything the UI shows comes from here. Main thread only.
public final class Party: ObservableObject {
    public enum Phase: Equatable {
        case idle
        /// Host: talking to the room server / waiting for the partner.
        case creatingRoom
        case waitingForPartner(code: String)
        /// Guest: looking up the code.
        case joining
        /// Both: found each other, setting up the call.
        case connecting
        case together
        case ended(String)
    }

    @Published public private(set) var phase: Phase = .idle {
        didSet { if phase == .together { wasTogether = true } }
    }
    /// The two of them were connected at some point.
    public private(set) var wasTogether = false
    @Published public private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published public private(set) var localVideoTrack: RTCVideoTrack?
    @Published public private(set) var filmName: String?
    /// Guest: share of the film received. Host: what the guest reported.
    @Published public private(set) var transferFraction: Double = 0
    @Published public private(set) var partnerCameraOn = true
    @Published public private(set) var partnerMicOn = true
    @Published public var micOn = true { didSet { call?.setMicMuted(!micOn); sendMediaState() } }
    @Published public var cameraOn = true { didSet { cameraOn ? call?.startCamera() : call?.stopCamera(); sendMediaState() } }
    @Published public var filmVolume: Float = 1 { didSet { hub.filmVolume = filmVolume } }
    @Published public var voiceVolume: Float = 1 { didSet { hub.voiceVolume = voiceVolume } }

    public let role: PeerRole
    public let playback: PlaybackController
    public let hub: AudioHub
    public private(set) var code: String?
    let settings: PartySettings

    private let signaling = SignalingClient()
    private(set) var call: CallSession?
    private var control: ControlChannel?
    private var fileChannel: RTCDataChannel?
    private(set) var sender: FileSender?
    public private(set) var receiver: FileReceiver?
    private var clock = ClockSync()
    /// Best measured round trip to the partner, seconds (guest only).
    public private(set) var clockRoundTrip: Double = 0
    private var pingTimer: Timer?
    private var pendingCode: String?
    private var cancellables: Set<AnyCancellable> = []

    public init(role: PeerRole, settings: PartySettings) {
        self.role = role
        self.settings = settings
        hub = AudioHub(mode: settings.audioMode)
        playback = PlaybackController(role: role, hub: hub)
        playback.send = { [weak self] message in self?.control?.send(message) }
        // Re-publish the playback controller's changes so SwiftUI views observing the party update.
        playback.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        signaling.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: Starting

    /// Host: share `film` and open a room.
    public func host(film: URL) throws {
        precondition(role == .host)
        let sender = try FileSender(url: film)
        self.sender = sender
        filmName = film.deletingPathExtension().lastPathComponent
        playback.load(asset: AVURLAsset(url: film))
        phase = .creatingRoom
        signaling.connect(to: settings.serverURL)
    }

    /// Guest: join the room with this code.
    public func join(code rawCode: String) {
        precondition(role == .guest)
        guard let code = RoomCode.normalize(rawCode) else { phase = .ended("That code doesn't look right."); return }
        pendingCode = code
        playback.startBuffering()
        phase = .joining
        signaling.connect(to: settings.serverURL)
    }

    public func leave() {
        control?.send(.bye)
        signaling.leaveRoom()
        teardownCall()
        signaling.disconnect()
        playback.unload()
        hub.stop()
        receiver = nil
        phase = .ended("")
    }

    // MARK: Room server

    private func handle(_ event: SignalingClient.Event) {
        switch event {
        case .connected:
            if role == .host { signaling.createRoom() } else if let pendingCode { signaling.joinRoom(code: pendingCode) }
        case .created(let code):
            self.code = code
            phase = .waitingForPartner(code: code)
        case .joined(let code):
            self.code = code
            phase = .connecting
            startCall()
        case .peerJoined:
            phase = .connecting
            startCall()
            call?.makeOffer()
        case .signal(let payload):
            call?.handleSignal(payload)
        case .peerLeft:
            partnerLeft()
        case .roomClosed:
            teardownCall()
            phase = .ended("The room was closed.")
        case .error(let error):
            switch error {
            case "no-such-room", "bad-code": phase = .ended("No movie night with that code. Check it and try again.")
            case "room-full": phase = .ended("That room already has two people in it.")
            default: if phase != .together { phase = .ended("Something went wrong (\(error)).") }
            }
        case .disconnected:
            // Once the call is up the room server is no longer needed.
            switch phase {
            case .together, .ended: break
            default: phase = .ended("Couldn't reach the SameSofa server. Check the internet connection and try again.")
            }
        }
    }

    private func startCall() {
        teardownCall()
        let call = CallSession(role: role, audio: hub, ice: settings.ice, camera: cameraOn ? settings.camera : .none)
        call.delegate = self
        self.call = call
        localVideoTrack = call.localVideoTrack
        call.setMicMuted(!micOn)
        call.announceChannels()
    }

    private func teardownCall() {
        pingTimer?.invalidate()
        pingTimer = nil
        control?.close()
        control = nil
        sender?.detach()
        fileChannel = nil
        call?.close()
        call = nil
        remoteVideoTrack = nil
        localVideoTrack = nil
    }

    private func partnerLeft() {
        teardownCall()
        playback.resetRemote()
        if role == .host, let code {
            phase = .waitingForPartner(code: code)
        } else {
            phase = .ended("Your partner left.")
        }
    }

    // MARK: Control messages

    private func controlOpened(_ channel: RTCDataChannel) {
        Log.debug("\(role) control channel handed, state \(channel.readyState.rawValue)")
        let control = ControlChannel(channel: channel) { [weak self] message in self?.handle(message) }
        self.control = control
        control.send(.hello(role: role, protocolVersion: ControlMessage.protocolVersion))
        sendMediaState()
        if role == .host, let sender {
            control.send(.fileInfo(sender.info))
            control.send(.timeline(playback.engine.timeline))
        } else {
            control.send(.buffering(playback.engine.localBuffering, position: playback.currentTime))
            startClockSync()
        }
    }

    private func handle(_ message: ControlMessage) {
        if case .want = message {} else if case .ping = message {} else if case .pong = message {} else if case .heartbeat = message {} else {
            Log.debug("\(role) got \(message)")
        }
        switch message {
        case .hello:
            break
        case .fileInfo(let info):
            guard role == .guest, receiver == nil else { return }
            receiveFilm(info)
        case .want(let chunks, let urgent):
            sender?.request(chunks, urgent: urgent)
        case .progress(let fraction):
            transferFraction = fraction
        case .timeline(let timeline):
            playback.receive(timeline)
        case .heartbeat(let timeline, let actual):
            playback.receiveHeartbeat(timeline, actual: actual)
        case .buffering(let buffering, let position):
            playback.remoteBuffering(buffering, at: position)
        case .ping(let t0):
            control?.send(.pong(t0: t0, t1: playback.localNow()))
        case .pong(let t0, let t1):
            clock.add(t0: t0, t1: t1, t2: playback.localNow())
            playback.clockOffset = clock.offset
            clockRoundTrip = clock.bestRoundTrip ?? 0
        case .mediaState(let camera, let mic):
            partnerCameraOn = camera
            partnerMicOn = mic
        case .bye:
            partnerLeft()
        }
    }

    private func sendMediaState() {
        control?.send(.mediaState(cameraOn: cameraOn, micOn: micOn))
    }

    private func startClockSync() {
        var count = 0
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            count += 1
            // Quick burst at first, then once every 2 seconds.
            if count <= 12 || count % 8 == 0 {
                self.control?.send(.ping(t0: self.playback.localNow()))
            }
        }
    }

    private func receiveFilm(_ info: FileInfo) {
        do {
            let receiver = try FileReceiver(info: info)
            self.receiver = receiver
            filmName = (info.name as NSString).deletingPathExtension
            receiver.requestChunks = { [weak self] chunks, urgent in self?.control?.send(.want(chunks: chunks, urgent: urgent)) }
            receiver.onProgress = { [weak self] fraction in
                self?.transferFraction = fraction
                self?.control?.send(.progress(fraction: fraction))
            }
            if let fileChannel { receiver.attach(fileChannel) }
            let asset = AVURLAsset(url: receiver.playerURL)
            asset.resourceLoader.setDelegate(receiver, queue: receiver.queue)
            playback.hasEnoughAhead = { [weak self, weak receiver] seconds in
                guard let self, let receiver else { return true }
                if receiver.isComplete { return true }
                let duration = self.playback.duration
                guard duration > 0 else { return false }
                let bytesPerSecond = Double(info.size) / duration
                let offset = Int64(seconds * bytesPerSecond)
                receiver.setPlayhead(offset: offset)
                let needed = min(Double(info.size - offset), bytesPerSecond * 8)
                return Double(receiver.contiguousBytes(from: offset)) >= needed
            }
            playback.load(asset: asset)
        } catch {
            Log.debug("receiver failed: \(error)")
            phase = .ended("Couldn't make room for the film on this Mac (\(error.localizedDescription)).")
        }
    }
}

extension Party: CallSessionDelegate {
    public func call(_ call: CallSession, wantsToSignal payload: [String: Any]) {
        signaling.signal(payload)
    }

    public func call(_ call: CallSession, connectionChanged connected: Bool) {
        guard call === self.call else { return }
        if connected {
            phase = .together
        } else if phase == .together {
            // The peer connection dropped without a goodbye (network change, sleep).
            partnerLeft()
        }
    }

    public func call(_ call: CallSession, controlChannelOpened channel: RTCDataChannel) {
        controlOpened(channel)
    }

    public func call(_ call: CallSession, fileChannelOpened channel: RTCDataChannel) {
        Log.debug("\(role) file channel handed, state \(channel.readyState.rawValue)")
        fileChannel = channel
        if role == .host { sender?.attach(channel) } else { receiver?.attach(channel) }
    }

    public func call(_ call: CallSession, remoteVideoTrack track: RTCVideoTrack) {
        remoteVideoTrack = track
    }
}

/// Wraps the "control" data channel: JSON messages, queued until it opens.
final class ControlChannel: NSObject, RTCDataChannelDelegate {
    private let channel: RTCDataChannel
    private let onMessage: (ControlMessage) -> Void
    private var queue: [ControlMessage] = []

    init(channel: RTCDataChannel, onMessage: @escaping (ControlMessage) -> Void) {
        self.channel = channel
        self.onMessage = onMessage
        super.init()
        ChannelRelay.attach(channel, to: self)
    }

    func send(_ message: ControlMessage) {
        guard channel.readyState == .open else { queue.append(message); return }
        channel.sendData(RTCDataBuffer(data: message.encoded(), isBinary: false))
    }

    func close() {
        ChannelRelay.attach(channel, to: nil)
        channel.close()
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async {
            guard self.channel.readyState == .open else { return }
            let pending = self.queue
            self.queue.removeAll()
            pending.forEach(self.send)
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let message = ControlMessage.decode(buffer.data) else { return }
        DispatchQueue.main.async { self.onMessage(message) }
    }
}
