import AVFoundation
import Combine
import Foundation
import SameSofaCore
import WebRTC

/// Progress of turning the host's film into something both Macs can play.
public struct Preparing: Equatable {
    /// 0...1
    public var fraction: Double
    /// Only rewrapping (seconds) rather than re-encoding (minutes).
    public var remuxOnly: Bool
    /// Times real time, when known.
    public var speed: Double?
    /// The film's timing information is damaged and is being rebuilt (or,
    /// if that failed, the picture is being re-encoded because of it).
    public var repairingTiming = false
}

public struct PartySettings {
    public var serverURL: URL
    public var ice: IceSettings
    public var audioMode: AudioMode
    /// Cancel the film from the microphone: automatic (unless headphones), always, never.
    public var echo: EchoSetting
    /// Leave spatial audio to the system instead of playing a plain downmix.
    public var systemSpatialAudio = false
    public var camera: CameraSource

    public init(serverURL: URL, ice: IceSettings = IceSettings(), audioMode: AudioMode = .live, echo: EchoSetting = .automatic, camera: CameraSource = .camera) {
        self.serverURL = serverURL
        self.ice = ice
        self.audioMode = audioMode
        self.echo = echo
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
    @Published public private(set) var transferFraction: Double = 0 {
        didSet { noteTransfer(transferFraction) }
    }
    /// "Sending the film: 126 MB of 2.1 GB · 5.2 MB/s", empty when nothing is moving.
    @Published public private(set) var transferLine = ""
    /// ICE failed or timed out while setting up: the view offers "Try again".
    @Published public private(set) var connectionFailed = false
    /// The partner's SameSofa is older or newer than this one (shown as a note; nothing is blocked).
    @Published public private(set) var versionNote: String?
    private var connectTimeout: DispatchWorkItem?
    /// The call dropped after it had been up (network change, sleep, a
    /// flaky link) and is being set up again in the same room. The film is
    /// held meanwhile; what has been received stays.
    @Published public private(set) var reconnecting = false
    /// How often the call was set up again (diagnostics, tests).
    public private(set) var reconnects = 0
    private var lastRestart = Date.distantPast
    private var dropGrace: DispatchWorkItem?
    private var rateMark: (time: Date, bytes: Double)?
    private var smoothedRate: Double = 0

    private func noteTransfer(_ fraction: Double) {
        guard let info = sharedFilm, info.size > 0 else { return }
        let bytes = fraction * Double(info.size)
        let now = Date()
        if let mark = rateMark {
            let dt = now.timeIntervalSince(mark.time)
            if dt >= 1 {
                let instant = max(0, bytes - mark.bytes) / dt
                smoothedRate = smoothedRate == 0 ? instant : smoothedRate * 0.6 + instant * 0.4
                rateMark = (now, bytes)
            }
        } else {
            rateMark = (now, bytes)
        }
        transferLine = fraction >= 1 ? "" : TransferText.line(sending: role == .host, received: Int64(bytes), total: info.size, rate: smoothedRate)
    }
    /// Host: the film is being converted to MP4 before it can be shared.
    /// Guest: the host said so. nil when nothing is being prepared.
    @Published public private(set) var preparing: Preparing?
    @Published public private(set) var partnerCameraOn = true
    @Published public private(set) var partnerMicOn = true
    @Published public var micOn = true { didSet { call?.setMicMuted(!micOn); sendMediaState() } }
    @Published public var cameraOn = true { didSet { cameraOn ? call?.startCamera() : call?.stopCamera(); sendMediaState() } }
    @Published public var filmVolume: Float = 1 { didSet { hub.filmVolume = filmVolume; playback.player.volume = filmVolume } }
    /// The film as shared: on the host its own description, on the guest the host's.
    @Published public private(set) var sharedFilm: FileInfo?
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
    private var preparer: FilmPreparer?
    private var lastPreparingSent = Date.distantPast
    /// Host: the file actually being sent (the original, or the converted MP4).
    public var sharedFile: URL? { sender?.url }
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
        hub.echoSetting = settings.echo
        playback = PlaybackController(role: role, hub: hub)
        hub.onRouteChange = { [weak self] in
            self?.playback.soundOutputChanged()
            self?.objectWillChange.send()
        }
        playback.systemSpatialAudio = settings.systemSpatialAudio
        playback.send = { [weak self] message in self?.control?.send(message) }
        // Re-publish the playback controller's changes so SwiftUI views observing the party update.
        playback.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        signaling.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: Starting

    /// Host: share `film` as it is and open a room.
    public func host(film: URL) throws {
        try host(film: film, check: .shareAsIs)
    }

    /// Host: open a room and share `film`, converting it first if `check`
    /// says so. The room (and its code) opens straight away; the guest is
    /// told about the film once the conversion has finished.
    public func host(film: URL, check: FilmCheck) throws {
        precondition(role == .host)
        filmName = film.deletingPathExtension().lastPathComponent
        switch check {
        case .shareAsIs:
            try startSharing(film, name: film.lastPathComponent, plan: nil)
        case .convert(let plan, let tools):
            guard FileManager.default.isReadableFile(atPath: film.path) else {
                throw FilmPreparerError("Couldn't read that file.")
            }
            let preparer = FilmPreparer(input: film, plan: plan, tools: tools)
            self.preparer = preparer
            preparing = Preparing(fraction: 0, remuxOnly: plan.isRemuxOnly, speed: nil, repairingTiming: plan.repairVideoTimestamps)
            preparer.onProgress = { [weak self, weak preparer] fraction, speed in
                // A late progress report must not bring "Preparing" back once sharing started.
                guard let self, let preparer, preparer === self.preparer, self.sender == nil else { return }
                self.preparing = Preparing(fraction: fraction, remuxOnly: preparer.activePlan.isRemuxOnly, speed: speed,
                                           repairingTiming: plan.repairVideoTimestamps)
                if Date().timeIntervalSince(self.lastPreparingSent) > 0.5 {
                    self.lastPreparingSent = Date()
                    self.control?.send(.preparing(fraction: fraction))
                }
            }
            let name = film.deletingPathExtension().appendingPathExtension("mp4").lastPathComponent
            preparer.start { [weak self, weak preparer] result in
                guard let self, let preparer, preparer === self.preparer else { return }
                switch result {
                case .success(let url):
                    do {
                        try self.startSharing(url, name: name, plan: preparer.activePlan)
                    } catch {
                        self.preparationFailed(error.localizedDescription)
                    }
                case .failure(let error):
                    if error is CancellationError { return }
                    self.preparationFailed(error.localizedDescription)
                }
            }
        }
        phase = .creatingRoom
        signaling.connect(to: settings.serverURL)
    }

    private func preparationFailed(_ message: String) {
        preparer = nil
        preparing = nil
        leave()
        phase = .ended(message)
    }

    /// Host: the film is ready; tell the guest (if already here) and start sending.
    private func startSharing(_ file: URL, name: String, plan: ConversionPlan?) throws {
        let sender = try FileSender(url: file, name: name, videoConverted: plan?.reencodesVideo ?? false,
                                    audioConverted: plan?.reencodesAudio ?? false)
        self.sender = sender
        sharedFilm = sender.info
        preparing = nil
        playback.load(asset: AVURLAsset(url: file))
        if let control {
            control.send(.fileInfo(sender.info))
            control.send(.timeline(playback.engine.timeline))
        }
        if let fileChannel { sender.attach(fileChannel) }
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
        if let preparer {
            preparer.cancel()
            self.preparer = nil
        }
        control?.send(.bye)
        signaling.leaveRoom()
        teardownCall()
        signaling.disconnect()
        playback.unload()
        hub.stop()
        receiver = nil
        sharedFilm = nil
        transferLine = ""; rateMark = nil; smoothedRate = 0
        sender?.detach()
        if let sender, sender.url.path.hasPrefix(FilmPreparer.directory.path) {
            try? FileManager.default.removeItem(at: sender.url)
        }
        sender = nil
        preparing = nil
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
            armConnectTimeout()
            startCall()
        case .peerJoined:
            phase = .connecting
            armConnectTimeout()
            startCall()
            call?.makeOffer()
        case .signal(let payload):
            // "restart": the host is about to offer a fresh call. "retry": the guest asks for one.
            // Older versions ignore both (they carry no description and no candidate).
            if payload["sdp"] == nil, payload["candidate"] == nil, let kind = payload["kind"] as? String {
                if kind == "restart", role == .guest { restartCall() }
                if kind == "retry", role == .host { hostRestart(force: false) }
                return
            }
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

    // MARK: Trying again in the same room

    /// "Try again": sets the call up afresh in the same room, with the same
    /// roles and new connection attempts on both sides. Works while
    /// connecting, after a failed attempt and after a drop.
    public func retryConnection() {
        guard call != nil || reconnecting || phase == .connecting else { return }
        if role == .host {
            hostRestart(force: true)
        } else {
            // The host makes the offer; ask for a new one.
            armConnectTimeout()
            signaling.signal(["kind": "retry"])
        }
    }

    private func hostRestart(force: Bool) {
        // Both sides usually notice a drop; one restart is enough.
        guard role == .host, force || Date().timeIntervalSince(lastRestart) > 3 else { return }
        lastRestart = Date()
        signaling.signal(["kind": "restart"])
        restartCall()
        call?.makeOffer()
    }

    /// A new call (new peer connection, new ICE) in place of the current one.
    private func restartCall() {
        reconnects += 1
        if phase == .together { holdForReconnect() } else { phase = .connecting }
        armConnectTimeout()
        startCall()
    }

    /// While the call is being set up again nobody misses anything: the film waits.
    private func holdForReconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        Log.debug("\(role) connection lost; reconnecting")
        playback.remoteBuffering(true, at: playback.currentTime)
    }

    /// The call was up and is not any more.
    private func connectionDropped() {
        guard !reconnecting else { return }
        holdForReconnect()
        armConnectTimeout()
        // A short interruption often heals by itself; otherwise set the call up again.
        dropGrace?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.reconnecting else { return }
            if self.role == .host { self.hostRestart(force: false) } else { self.signaling.signal(["kind": "retry"]) }
        }
        dropGrace = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func connectionRestored() {
        dropGrace?.cancel()
        guard reconnecting else { return }
        reconnecting = false
        Log.debug("\(role) reconnected")
        guard role == .host else {
            playback.remoteBuffering(false, at: playback.currentTime)
            return
        }
        // The two sides rarely notice a drop at the same moment. The host
        // waits for the guest to say where its film stopped (the first thing
        // a guest sends on a new control channel) and restarts from the
        // earlier of the two positions.
        awaitingPartnerPosition = true
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.awaitingPartnerPosition else { return }
            self.awaitingPartnerPosition = false
            self.playback.remoteBuffering(false, at: self.playback.currentTime)
        }
        partnerPositionTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    private var awaitingPartnerPosition = false
    private var partnerPositionTimeout: DispatchWorkItem?

    /// Test hook: the peer connection goes away without a goodbye, as when a network disappears.
    public func dropConnectionForTesting() {
        call?.close()
        connectionDropped()
    }

    private func armConnectTimeout() {
        connectionFailed = false
        connectTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .connecting || self.reconnecting else { return }
            self.failConnection()
        }
        connectTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func failConnection() {
        connectTimeout?.cancel()
        connectionFailed = true
        Log.debug("connection failed")
    }

    private func teardownCall() {
        connectTimeout?.cancel()
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
        versionNote = nil
        dropGrace?.cancel()
        partnerPositionTimeout?.cancel()
        awaitingPartnerPosition = false
        reconnecting = false
        connectionFailed = false
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
        if role == .host {
            if let sender {
                control.send(.fileInfo(sender.info))
                control.send(.timeline(playback.engine.timeline))
            } else if let preparing {
                control.send(.preparing(fraction: preparing.fraction))
            }
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
        case .hello(_, let version):
            Log.debug("\(role) partner speaks protocol \(version), this copy \(ControlMessage.protocolVersion)")
            switch ControlMessage.compatibility(with: version) {
            case .same: versionNote = nil
            case .note(let text): versionNote = text
            case .incompatible(let text):
                leave()
                phase = .ended(text)
            }
        case .fileInfo(let info):
            guard role == .guest, receiver == nil else { return }
            preparing = nil
            receiveFilm(info)
        case .want(let chunks, let urgent, let reset):
            sender?.request(chunks, urgent: urgent, reset: reset ?? false)
        case .progress(let fraction):
            transferFraction = fraction
        case .timeline(let timeline):
            playback.receive(timeline)
        case .heartbeat(let timeline, let actual):
            playback.receiveHeartbeat(timeline, actual: actual)
        case .buffering(let buffering, let position):
            if awaitingPartnerPosition {
                awaitingPartnerPosition = false
                partnerPositionTimeout?.cancel()
                playback.partnerStopped(at: position)
                // Still loading on their side: stay held until they say otherwise.
                if !buffering { playback.remoteBuffering(false, at: position) }
            } else {
                playback.remoteBuffering(buffering, at: position)
            }
        case .ping(let t0):
            control?.send(.pong(t0: t0, t1: playback.localNow()))
        case .pong(let t0, let t1):
            clock.add(t0: t0, t1: t1, t2: playback.localNow())
            playback.clockOffset = clock.offset
            clockRoundTrip = clock.bestRoundTrip ?? 0
        case .preparing(let fraction):
            if role == .guest, receiver == nil { preparing = Preparing(fraction: fraction, remuxOnly: false, speed: nil) }
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
            sharedFilm = info
            filmName = (info.name as NSString).deletingPathExtension
            receiver.requestChunks = { [weak self] chunks, urgent, jump in self?.control?.send(.want(chunks: chunks, urgent: urgent, reset: jump ? true : nil)) }
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
            connectTimeout?.cancel()
            connectionFailed = false
            phase = .together
            connectionRestored()
        } else if reconnecting {
            // Still down; the restart and its timeout are already under way.
        } else if phase == .connecting {
            failConnection()
        } else if phase == .together {
            // The peer connection dropped without a goodbye (network change,
            // sleep): try to get it back. If the partner has really gone, the
            // room server says so (peer-left) and that ends it.
            connectionDropped()
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
        queue.append(message)
        flush()
    }

    private var retryScheduled = false

    /// Sends what is queued, in order. `sendData` refuses messages when the
    /// connection's send buffer is full (the film transfer shares it); those
    /// are kept and retried shortly instead of being lost.
    private func flush() {
        guard channel.readyState == .open else { return }
        while let message = queue.first {
            guard channel.sendData(RTCDataBuffer(data: message.encoded(), isBinary: false)) else {
                if !retryScheduled {
                    retryScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        self.retryScheduled = false
                        self.flush()
                    }
                }
                return
            }
            queue.removeFirst()
        }
    }

    func close() {
        ChannelRelay.attach(channel, to: nil)
        channel.close()
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { self.flush() }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let message = ControlMessage.decode(buffer.data) else { return }
        DispatchQueue.main.async { self.onMessage(message) }
    }
}
