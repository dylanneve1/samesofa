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

/// A film waiting in the host's "Up next" queue.
public struct QueuedFilm: Identifiable, Equatable {
    public enum State: Equatable {
        case waiting
        /// Being looked at / converted in the background (0...1).
        case preparing(Double)
        case ready
        case failed(String)
    }

    public let id: UUID
    public let url: URL
    public var name: String
    public var state: State
}

/// "Next: <name>" with a countdown, on both sides, when a film has ended and another one is queued.
public struct NextCard: Equatable {
    public var name: String
    public var deadline: Date
}

/// One evening together: the room, the call, and whatever film is being
/// watched at the moment, if any. The room and the call do not depend on the
/// film: the host can open a room without one, change it, or close it, and
/// the two stay connected. Everything the UI shows comes from here. Main
/// thread only.
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
    /// Which parts of the film the guest has, as shares of the film (0...1), on both sides (for the seek bar).
    @Published public private(set) var receivedRanges: [ClosedRange<Double>] = []
    /// The partner's SameSofa is older or newer than this one (shown as a note; nothing is blocked).
    @Published public private(set) var versionNote: String?
    private var connectTimeout: DispatchWorkItem?
    /// The call dropped after it had been up (network change, sleep, a
    /// flaky link) and is being set up again in the same room. The film is
    /// held meanwhile; what has been received stays.
    @Published public private(set) var reconnecting = false
    /// How often the call was set up again (diagnostics, tests).
    public private(set) var reconnects = 0
    /// How many peer connections this party has made (1 for an evening without a drop).
    public private(set) var callsStarted = 0
    /// "ice connected", "peer connected", ... of every call, in order (diagnostics, tests).
    public private(set) var connectionLog: [String] = []
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
    /// Host: the file that was picked is being looked at. Guest: the host
    /// has picked another film and it has not arrived yet.
    @Published public private(set) var choosingFilm = false
    /// Why the film that was picked cannot be watched (host: not a film,
    /// conversion failed; guest: no room on this Mac). The room goes on.
    @Published public var filmNotice: String?
    @Published public private(set) var partnerCameraOn = true
    @Published public private(set) var partnerMicOn = true
    @Published public var micOn = true { didSet { call?.setMicMuted(!micOn); sendMediaState() } }
    @Published public var cameraOn = true { didSet { cameraOn ? call?.startCamera() : call?.stopCamera(); sendMediaState() } }
    @Published public var filmVolume: Float = 1 { didSet { hub.filmVolume = filmVolume; playback.player.volume = filmVolume } }
    /// The film as shared: on the host its own description, on the guest the host's. nil: no film right now.
    @Published public private(set) var sharedFilm: FileInfo?
    @Published public var voiceVolume: Float = 1 { didSet { hub.voiceVolume = voiceVolume } }

    public let role: PeerRole
    public let playback: PlaybackController
    public let hub: AudioHub
    public private(set) var code: String?
    let settings: PartySettings
    /// Where films are kept for resuming (tests give each party its own).
    public var filmCache: FilmCache = .shared

    private let signaling = SignalingClient()
    private(set) var call: CallSession?
    private var control: ControlChannel?
    /// The film channels of the current call, by label.
    private var fileChannels: [String: RTCDataChannel] = [:]
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

    // Which film the room is on.
    /// Host: the numbering of films in this room and what the guest has confirmed.
    public private(set) var turn = FilmTurn()
    /// Host: the sequence number the current film's timeline started at.
    private var filmSeq = 0
    /// Host: the label of the channel the current film is sent on in this call (nil: none assigned).
    private var filmChannelLabel: String?
    /// Host: the call's first film channel ("file") has been given to a film.
    private var firstChannelUsed = false
    /// Host: SHA-256 of the whole current film, once worked out.
    private var filmHash: String?
    /// Host: a cached converted film in use (released when the film is over).
    private var preparedID: String?
    /// Guest: the number of the film it is on (nil: the host has not said yet).
    public private(set) var guestFilm: Int?
    /// Guest: the label of the channel the current film arrives on.
    private var wantedChannel = FileInfo.firstChannel
    /// The partner's protocol version, from its hello (nil: nobody here, or not said yet).
    public private(set) var partnerVersion: Int?
    /// Host: this partner has been told about a film on this visit.
    private var filmAnnounced = false

    // Up next.
    /// Host: the films that follow, in order.
    @Published public private(set) var queue: [QueuedFilm] = []
    /// Both: the name of the film that comes next (the guest's from the host), nil: none.
    @Published public private(set) var upNextName: String?
    /// Host: how much of the next film the partner already has (0...1); nil: it is not being sent ahead.
    @Published public private(set) var nextFetched: Double?
    /// Both: the film has ended and the next one is about to start.
    @Published public private(set) var nextCard: NextCard?
    public static let maxQueue = 8
    /// Seconds between the end of a film and the start of the next.
    public static let nextDelay = 5.0

    private struct PreparedNext {
        let id: UUID
        let file: URL
        let name: String
        let videoConverted: Bool
        let audioConverted: Bool
        /// Its entry in the film cache, if it is kept there.
        let cacheID: String?
    }
    /// Host: the first film of the queue, looked at and (if need be) converted, ready to be shared.
    private var preparedNext: PreparedNext?
    private var nextPreparer: FilmPreparer?
    private var nextWork = 0
    /// Host: sends the next film ahead while the current one plays.
    private var nextSender: FileSender?
    private var nextChannelLabel: String?
    private var nextChannelCount = 0
    /// Host: the partner cannot keep the next film (no room, keeping switched off): not offered again.
    private var nextDeclined: UUID?
    /// Host: the upload rate the last film reached, bytes per second (0: not measured).
    public private(set) var lastFilmRate: Double = 0
    /// Host: the limit the next film is sent ahead with, bytes per second (nil: none).
    public private(set) var prefetchLimit: Double?
    /// Host: "next" was cancelled for this film number; it is not offered again by itself.
    private var nextDismissedFor: Int?
    private var nextTimer: Timer?
    private var endWatch: AnyCancellable?
    private var playWhenLoaded = false
    private var autoPlayWatch: AnyCancellable?
    /// Guest: fetches the next film in the background.
    private var prefetcher: FileReceiver?
    private var prefetchChannel: String?
    /// Guest: where the background fetch stands (tests).
    public var prefetchStatus: FileReceiver.Status? { prefetcher?.status }

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
        if role == .host {
            // The film ran to its end: if another one is queued, it follows by itself.
            endWatch = playback.$reachedEnd.removeDuplicates().sink { [weak self] ended in
                DispatchQueue.main.async { if ended { self?.filmEnded() } }
            }
        }
    }

    // MARK: Starting

    /// Host: open a room. No film is needed: the two can see and hear each
    /// other, and a film can be chosen (and changed) at any time.
    public func openRoom() {
        precondition(role == .host)
        guard phase == .idle else { return }
        phase = .creatingRoom
        signaling.connect(to: settings.serverURL)
    }

    /// Host: share `film` as it is and open a room.
    public func host(film: URL) throws {
        try host(film: film, check: .shareAsIs)
    }

    /// Host: open a room and share `film`, converting it first if `check`
    /// says so. The room (and its code) opens straight away; the guest is
    /// told about the film once the conversion has finished.
    public func host(film: URL, check: FilmCheck) throws {
        precondition(role == .host)
        try setFilm(film, check: check)
        openRoom()
    }

    // MARK: The film (host)

    /// Something to do with a film is going on (one is loaded, being looked at or being prepared).
    public var hasFilmActivity: Bool { sharedFilm != nil || choosingFilm || preparing != nil }

    /// The partner here is too old to follow a change of film (1.2.1 and earlier).
    public var partnerIsOld: Bool { partnerVersion.map { $0 < ControlMessage.filmChangeVersion } ?? false }

    /// Host: can the film be changed or closed right now? Not while an
    /// older partner already has a film: their copy can only ever take one.
    public var canChangeFilm: Bool { role == .host && !(partnerIsOld && filmAnnounced) }

    /// Host: another film was picked (or the first one). The current film,
    /// if any, ends on both sides at once; the call and the room go on. The
    /// file is looked at, converted if need be, then shared.
    public func changeFilm(to film: URL, inspect: @escaping (URL) async throws -> FilmCheck = { try await FilmPreparer.inspect($0) }) {
        guard role == .host, canChangeFilm else {
            Log.debug("\(role) change of film refused: the partner's copy is too old to follow")
            return
        }
        let number = beginFilmChange(name: film.deletingPathExtension().lastPathComponent)
        Task { @MainActor in
            do {
                // Screenshots only: time to capture "your partner is choosing another film".
                if let slow = ProcessInfo.processInfo.environment["SAMESOFA_TEST_SLOW_INSPECT"].flatMap(Double.init) {
                    try? await Task.sleep(for: .seconds(slow))
                }
                let check = try await inspect(film)
                // Changed again (or closed) while this file was being looked at.
                guard self.turn.current == number, self.choosingFilm else { return }
                try self.share(film, check: check)
            } catch {
                guard self.turn.current == number else { return }
                let reason = error is FilmPreparerError ? error.localizedDescription
                    : "Couldn't open that file (\(error.localizedDescription)). Check that it is still where it was, or pick another film."
                self.filmFailed(reason)
            }
        }
    }

    /// Host: share a film that has already been looked at (`FilmPreparer.inspect`).
    public func setFilm(_ film: URL, check: FilmCheck) throws {
        guard role == .host, canChangeFilm else { return }
        beginFilmChange(name: film.deletingPathExtension().lastPathComponent)
        do {
            try share(film, check: check)
        } catch {
            filmFailed(nil)
            throw error
        }
    }

    /// Host: stop watching this film. Both go back to just being in the room together.
    public func closeFilm() {
        guard role == .host, canChangeFilm, hasFilmActivity else {
            if role == .host, !canChangeFilm { Log.debug("\(role) closing the film refused: the partner's copy is too old to follow") }
            return
        }
        Log.debug("host: film \(turn.current) closed")
        endFilm()
        sendFilmState()
        prepareNext()
    }

    /// Ends the current film on this side and starts the next number.
    @discardableResult
    private func beginFilmChange(name: String) -> Int {
        endFilm()
        choosingFilm = true
        filmName = name
        Log.debug("host: film \(turn.current) chosen")
        sendFilmState()
        return turn.current
    }

    private func filmFailed(_ reason: String?) {
        preparer = nil
        preparing = nil
        choosingFilm = false
        filmName = nil
        filmNotice = reason
        sendFilmState()
        prepareNext()
    }

    /// Host: everything of the current film goes; the room, the call and the code stay.
    private func endFilm() {
        stopPrefetch()
        playWhenLoaded = false
        autoPlayWatch = nil
        if let preparer {
            preparer.cancel()
            self.preparer = nil
        }
        if let sender {
            sender.stop()
            if sender.url.path.hasPrefix(FilmPreparer.parentDirectory.path) { try? FileManager.default.removeItem(at: sender.url) }
        }
        sender = nil
        if let preparedID { filmCache.release(preparedID) }
        preparedID = nil
        filmHash = nil
        closeFilmChannel()
        clearFilmState()
        turn.advance()
        filmSeq = playback.startOver().seq
        refreshVersionNote()
    }

    /// What both roles forget when a film is over.
    private func clearFilmState() {
        sharedFilm = nil
        filmName = nil
        preparing = nil
        choosingFilm = false
        filmNotice = nil
        transferFraction = 0
        transferLine = ""; rateMark = nil; smoothedRate = 0
        receivedRanges = []
        nextTimer?.invalidate()
        nextTimer = nil
        nextCard = nil
    }

    /// Host: the film has been looked at; convert it if need be, then share it.
    private func share(_ film: URL, check: FilmCheck) throws {
        switch check {
        case .shareAsIs:
            try startSharing(film, name: film.lastPathComponent, videoConverted: false, audioConverted: false)
        case .convert(let plan, let tools):
            guard FileManager.default.isReadableFile(atPath: film.path) else {
                throw FilmPreparerError("Couldn't read that file.")
            }
            let name = film.deletingPathExtension().appendingPathExtension("mp4").lastPathComponent
            // A hardware encoder does not produce the same bytes twice, so the
            // converted film is kept and found again by what went in and how.
            let key = Self.conversionKey(film: film, plan: plan, tools: tools)
            if let key, let kept = filmCache.prepared(key: key) {
                Log.debug("host: converted film found in the cache")
                preparedID = kept.id
                try startSharing(kept.file, name: name, videoConverted: kept.videoConverted, audioConverted: kept.audioConverted)
                return
            }
            let preparer = FilmPreparer(input: film, plan: plan, tools: tools)
            self.preparer = preparer
            choosingFilm = false
            preparing = Preparing(fraction: 0, remuxOnly: plan.isRemuxOnly, speed: nil, repairingTiming: plan.repairVideoTimestamps)
            control?.send(.preparing(fraction: 0))
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
            conversionsRun += 1
            preparer.start { [weak self, weak preparer] result in
                guard let self, let preparer, preparer === self.preparer else { return }
                self.preparer = nil
                switch result {
                case .success(let url):
                    do {
                        let active = preparer.activePlan
                        var file = url
                        if let key, let kept = self.filmCache.adoptPrepared(key: key, file: url, videoConverted: active.reencodesVideo,
                                                                            audioConverted: active.reencodesAudio) {
                            self.preparedID = kept.id
                            file = kept.file
                        }
                        try self.startSharing(file, name: name, videoConverted: active.reencodesVideo, audioConverted: active.reencodesAudio)
                    } catch {
                        self.filmFailed(error.localizedDescription)
                    }
                case .failure(let error):
                    if error is CancellationError { return }
                    self.filmFailed(error.localizedDescription)
                }
            }
        }
    }

    private static func conversionKey(film: URL, plan: ConversionPlan, tools: FFmpegTools) -> String? {
        guard let source = try? FilmFingerprint.compute(file: film) else { return nil }
        var sidecarPrint: String?
        var arguments = plan.ffmpegArguments(input: "IN", output: "OUT")
        if case .sidecar(let path) = plan.subtitles {
            sidecarPrint = try? FilmFingerprint.compute(file: URL(fileURLWithPath: path))
            arguments = arguments.map { $0 == path ? "SIDECAR" : $0 }
        }
        let tool = ((try? FileManager.default.attributesOfItem(atPath: tools.ffmpeg.path))?[.size] as? NSNumber)?.stringValue ?? "ffmpeg"
        return FilmFingerprint.conversionKey(source: source, sidecar: sidecarPrint, arguments: arguments, tool: tool)
    }

    /// Host: the film is ready; tell the guest (if already here) and start sending.
    private func startSharing(_ file: URL, name: String, videoConverted: Bool, audioConverted: Bool) throws {
        let sender = try FileSender(url: file, name: name, videoConverted: videoConverted, audioConverted: audioConverted)
        self.sender = sender
        choosingFilm = false
        preparing = nil
        filmNotice = nil
        // A partner who is here has to fetch the film first: until they say
        // they are ready, the film waits for them.
        if partnerPresent { playback.remoteBuffering(true, at: 0) }
        playback.load(asset: AVURLAsset(url: file))
        assignFilmChannel()
        sharedFilm = announcedInfo()
        Log.debug("host: film \(turn.current) shared (\(sender.info.chunkCount) chunks)")
        sendFilmState()
        refreshVersionNote()
        if playWhenLoaded {
            // The next film of the queue starts by itself, as soon as it can (together, when the partner is ready).
            autoPlayWatch = playback.$isLoaded.filter { $0 }.first().sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.playWhenLoaded, self.sender === sender else { return }
                    self.playWhenLoaded = false
                    self.playback.play()
                }
            }
        }
        prepareNext()
        let number = turn.current
        sender.computeFullHash { [weak self, weak sender] hash in
            guard let self, let sender, sender === self.sender, self.turn.current == number else { return }
            self.filmHash = hash
            self.control?.send(.filmHash(film: number, sha256: hash))
        }
    }

    /// A partner is in the room (connected, or being reconnected).
    private var partnerPresent: Bool { phase == .together || phase == .connecting }

    /// Host: the film as the guest is told about it.
    private func announcedInfo() -> FileInfo? {
        guard var info = sender?.info else { return nil }
        info.film = turn.current
        info.channel = filmChannelLabel ?? FileInfo.firstChannel
        info.seq = filmSeq
        return info
    }

    /// Host: tells the partner where the room stands: this film, a film on its way, or none.
    private func sendFilmState() {
        guard role == .host, let control else { return }
        if let info = announcedInfo() {
            control.send(.fileInfo(info))
            control.send(.timeline(playback.engine.timeline))
            if let filmHash { control.send(.filmHash(film: turn.current, sha256: filmHash)) }
            filmAnnounced = true
            refreshVersionNote()
        } else if choosingFilm || preparing != nil {
            control.send(.filmChanging(film: turn.current, seq: filmSeq))
            if let preparing { control.send(.preparing(fraction: preparing.fraction)) }
        } else {
            control.send(.noFilm(film: turn.current, seq: filmSeq))
        }
    }

    /// Host: gives the current film a channel of its own on the current call.
    /// The first film of a call takes the channel every version knows
    /// ("file"); each later one gets a new channel.
    private func assignFilmChannel() {
        guard role == .host, let call, let sender, filmChannelLabel == nil else { return }
        if !firstChannelUsed, let channel = fileChannels[FileInfo.firstChannel] {
            firstChannelUsed = true
            filmChannelLabel = FileInfo.firstChannel
            sender.attach(channel)
        } else if firstChannelUsed {
            let label = FileInfo.laterChannelPrefix + String(turn.current)
            guard let channel = call.openFilmChannel(label: label) else { return }
            fileChannels[label] = channel
            filmChannelLabel = label
            sender.attach(channel)
        }
    }

    /// Host: the film's channel is closed with the film. What was still
    /// queued on it is dropped, and whatever is already on its way arrives on
    /// a channel nobody listens to any more.
    private func closeFilmChannel() {
        guard let label = filmChannelLabel else { return }
        filmChannelLabel = nil
        if let channel = fileChannels.removeValue(forKey: label) {
            ChannelRelay.attach(channel, to: nil)
            channel.close()
        }
    }

    /// Guest: join the room with this code.
    public func join(code rawCode: String) {
        precondition(role == .guest)
        guard let code = RoomCode.normalize(rawCode) else { phase = .ended("That code doesn't look right. It has six letters and digits."); return }
        pendingCode = code
        // A host before 1.3 always has a film and expects the guest to say it is loading.
        playback.startBuffering()
        phase = .joining
        signaling.connect(to: settings.serverURL)
    }

    /// Leaves the room: the call ends (the host leaving closes the room).
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
        receiver?.cancel()
        receiver = nil
        playback.hasEnoughAhead = nil
        if let sender {
            sender.stop()
            if sender.url.path.hasPrefix(FilmPreparer.parentDirectory.path) { try? FileManager.default.removeItem(at: sender.url) }
        }
        sender = nil
        if let preparedID { filmCache.release(preparedID) }
        preparedID = nil
        dropNextWork()
        stopPrefetching()
        queue = []
        upNextName = nil
        clearFilmState()
        phase = .ended("")
    }

    // MARK: Up next (host)

    /// A queue is possible with nobody here yet or with a partner on 1.3.
    public var canQueue: Bool { role == .host && !partnerIsOld }

    /// Host: this film follows when the current one (and whatever is queued before it) is over.
    public func addToQueue(_ film: URL) {
        guard canQueue, queue.count < Self.maxQueue else { return }
        queue.append(QueuedFilm(id: UUID(), url: film, name: film.deletingPathExtension().lastPathComponent, state: .waiting))
        Log.debug("host: \(queue.count) film(s) queued")
        queueChanged()
    }

    public func removeFromQueue(_ id: UUID) {
        guard role == .host, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index)
        if index == 0 { dropNextWork() }
        queueChanged()
    }

    private func setQueueState(_ id: UUID, _ state: QueuedFilm.State) {
        guard let index = queue.firstIndex(where: { $0.id == id }), queue[index].state != state else { return }
        queue[index].state = state
    }

    private func queueChanged() {
        let name = queue.first?.name
        if name != upNextName {
            upNextName = name
            control?.send(.upNext(name: name))
        }
        if queue.isEmpty, nextCard != nil { cancelNext() }
        prepareNext()
    }

    /// Forgets what was prepared or being prepared for the head of the queue.
    private func dropNextWork() {
        nextWork += 1
        if let nextPreparer {
            nextPreparer.cancel()
            self.nextPreparer = nil
        }
        if let prepared = preparedNext {
            if let id = prepared.cacheID { filmCache.release(id) }
            if prepared.file.path.hasPrefix(FilmPreparer.parentDirectory.path) { try? FileManager.default.removeItem(at: prepared.file) }
        }
        preparedNext = nil
        stopPrefetch()
    }

    /// Host: gets the head of the queue ready in the background (looks at it, converts it if it has to
    /// be), then sends it ahead. One conversion at a time: never while the current film is being converted.
    private func prepareNext() {
        guard role == .host, let first = queue.first else { return }
        if preparedNext?.id == first.id { startPrefetch(); return }
        guard nextPreparer == nil, first.state == .waiting, preparer == nil, !choosingFilm else { return }
        setQueueState(first.id, .preparing(0))
        nextWork += 1
        let work = nextWork, id = first.id, url = first.url
        Task { @MainActor in
            do {
                let check = try await FilmPreparer.inspect(url)
                guard self.nextWork == work, self.queue.first?.id == id else { return }
                switch check {
                case .shareAsIs:
                    self.nextReady(PreparedNext(id: id, file: url, name: url.lastPathComponent, videoConverted: false, audioConverted: false, cacheID: nil))
                case .convert(let plan, let tools):
                    let name = url.deletingPathExtension().appendingPathExtension("mp4").lastPathComponent
                    let key = Self.conversionKey(film: url, plan: plan, tools: tools)
                    if let key, let kept = self.filmCache.prepared(key: key) {
                        self.nextReady(PreparedNext(id: id, file: kept.file, name: name, videoConverted: kept.videoConverted,
                                                    audioConverted: kept.audioConverted, cacheID: kept.id))
                        return
                    }
                    let preparer = FilmPreparer(input: url, plan: plan, tools: tools)
                    self.nextPreparer = preparer
                    preparer.onProgress = { [weak self, weak preparer] fraction, _ in
                        guard let self, let preparer, preparer === self.nextPreparer else { return }
                        self.setQueueState(id, .preparing(fraction))
                    }
                    self.conversionsRun += 1
                    preparer.start { [weak self, weak preparer] result in
                        guard let self, let preparer, preparer === self.nextPreparer else { return }
                        self.nextPreparer = nil
                        switch result {
                        case .success(let output):
                            let active = preparer.activePlan
                            var file = output, cacheID: String?
                            if let key, let kept = self.filmCache.adoptPrepared(key: key, file: output, videoConverted: active.reencodesVideo,
                                                                                audioConverted: active.reencodesAudio) {
                                file = kept.file
                                cacheID = kept.id
                            }
                            self.nextReady(PreparedNext(id: id, file: file, name: name, videoConverted: active.reencodesVideo,
                                                        audioConverted: active.reencodesAudio, cacheID: cacheID))
                        case .failure(let error):
                            if error is CancellationError { return }
                            self.setQueueState(id, .failed(error.localizedDescription))
                        }
                    }
                }
            } catch {
                guard self.nextWork == work, self.queue.first?.id == id else { return }
                self.setQueueState(id, .failed(error.localizedDescription))
            }
        }
    }

    private func nextReady(_ prepared: PreparedNext) {
        guard queue.first?.id == prepared.id else {
            // No longer the head of the queue.
            if let id = prepared.cacheID { filmCache.release(id) }
            return
        }
        preparedNext = prepared
        setQueueState(prepared.id, .ready)
        startPrefetch()
    }

    /// Host: sends the next film ahead, on a channel of its own, once the current film has arrived
    /// completely (it never competes with the film being watched) and at a limited rate (it leaves
    /// room for the call): 60 % of what the last film's transfer reached. The guest keeps it in its
    /// film cache, so when its turn comes nothing (or only the rest) has to be sent.
    private func startPrefetch() {
        guard role == .host, let prepared = preparedNext, nextSender == nil, nextDeclined != prepared.id, let call, let control,
              turn.partnerFollowsChanges, turn.guestIsOnCurrentFilm, phase == .together, !reconnecting,
              sender == nil ? !hasFilmActivity : transferFraction >= 1 else { return }
        prefetchLimit = lastFilmRate > 0 ? max(128 * 1024, lastFilmRate * 0.6) : nil
        guard let ahead = try? FileSender(url: prepared.file, name: prepared.name, videoConverted: prepared.videoConverted,
                                          audioConverted: prepared.audioConverted, rateLimit: prefetchLimit) else { return }
        nextChannelCount += 1
        let label = FileInfo.laterChannelPrefix + "next-\(nextChannelCount)"
        guard let channel = call.openFilmChannel(label: label) else { return }
        fileChannels[label] = channel
        nextChannelLabel = label
        nextSender = ahead
        ahead.attach(channel)
        nextFetched = 0
        var info = ahead.info
        info.channel = label
        Log.debug("host: sending the next film ahead (\(info.chunkCount) chunks, limit \(prefetchLimit.map { "\(Int($0 / 1024)) KiB/s" } ?? "none"))")
        control.send(.prefetch(info))
    }

    private func stopPrefetch() {
        guard nextSender != nil || nextChannelLabel != nil else { return }
        nextSender?.stop()
        nextSender = nil
        if let label = nextChannelLabel, let channel = fileChannels.removeValue(forKey: label) {
            ChannelRelay.attach(channel, to: nil)
            channel.close()
        }
        nextChannelLabel = nil
        nextFetched = nil
        control?.send(.prefetchStop)
    }

    /// Host: the film ran to its end. With a film queued, both see "Next: …" and it starts after a few seconds.
    private func filmEnded() {
        guard role == .host, sharedFilm != nil, let first = queue.first, nextCard == nil, nextDismissedFor != turn.current, canChangeFilm else { return }
        nextCard = NextCard(name: first.name, deadline: Date().addingTimeInterval(Self.nextDelay))
        control?.send(.nextIn(seconds: Self.nextDelay, name: first.name))
        nextTimer?.invalidate()
        nextTimer = Timer.scheduledTimer(withTimeInterval: Self.nextDelay, repeats: false) { [weak self] _ in
            guard let self, self.nextCard != nil else { return }
            self.playNext()
        }
    }

    /// Either side: "not now". The film stays where it ended; the queue stays as it is.
    public func cancelNext() {
        guard nextCard != nil else { return }
        dismissNext()
        control?.send(.nextCancel)
    }

    private func dismissNext() {
        nextTimer?.invalidate()
        nextTimer = nil
        nextCard = nil
        if role == .host { nextDismissedFor = turn.current }
    }

    /// Host: the next film of the queue, now. It starts playing by itself as soon as both are ready.
    public func playNext() {
        guard role == .host, canChangeFilm, let item = queue.first else { return }
        queue.removeFirst()
        let prepared = preparedNext?.id == item.id ? preparedNext : nil
        preparedNext = nil
        if prepared == nil { dropNextWork() }
        Log.debug("host: next film from the queue (\(prepared == nil ? "not prepared yet" : "prepared"))")
        if let prepared {
            // Already looked at and converted: shared at once. What the guest fetched ahead is found in its cache.
            beginFilmChange(name: item.name)
            preparedID = prepared.cacheID
            playWhenLoaded = true
            do {
                try startSharing(prepared.file, name: prepared.name, videoConverted: prepared.videoConverted, audioConverted: prepared.audioConverted)
            } catch {
                filmFailed(error.localizedDescription)
            }
        } else {
            changeFilm(to: item.url)
            playWhenLoaded = true
        }
        queueChanged()
    }

    // MARK: Up next (guest)

    /// Guest: fetch the film that comes next, in the background, into the film cache.
    private func startPrefetching(_ info: FileInfo) {
        stopPrefetching()
        guard info.size > 0, info.chunkSize >= 1024, info.chunkSize <= 1 << 22, info.fingerprint != nil,
              let receiver = try? FileReceiver(info: info, cache: filmCache), receiver.isKept else {
            // It cannot be kept here (no room, or keeping is switched off): it comes when its turn comes.
            control?.send(.prefetchProgress(fraction: -1))
            return
        }
        prefetcher = receiver
        prefetchChannel = info.channel
        receiver.requestChunks = { [weak self, weak receiver] chunks, _, _ in
            guard let self, let receiver, receiver === self.prefetcher else { return }
            self.control?.send(.prefetchWant(chunks: chunks))
        }
        receiver.onProgress = { [weak self, weak receiver] fraction in
            guard let self, let receiver, receiver === self.prefetcher else { return }
            self.control?.send(.prefetchProgress(fraction: fraction))
        }
        receiver.reportNow()
        if let label = info.channel, let channel = fileChannels[label] { receiver.attach(channel) }
    }

    private func stopPrefetching() {
        prefetcher?.cancel()
        prefetcher = nil
        if let label = prefetchChannel { fileChannels[label] = nil }
        prefetchChannel = nil
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
                if holdReconnectForTesting { return }
                if kind == "restart", role == .guest { restartCall() }
                if kind == "retry", role == .host { hostRestart(force: false) }
                return
            }
            call?.handleSignal(payload)
        case .peerLeft:
            partnerLeft()
        case .roomClosed:
            teardownCall()
            phase = .ended("Your partner closed the room.")
        case .error(let error):
            let message = Self.roomErrorText(error)
            switch error {
            case "no-such-room", "bad-code", "room-full": phase = .ended(message)
            default: if phase != .together { phase = .ended(message) }
            }
        case .disconnected:
            // Once the call is up the room server is no longer needed.
            switch phase {
            case .together, .ended: break
            default: phase = .ended("Couldn't reach the SameSofa server. Check your internet connection and try again.")
            }
        }
    }

    /// What to tell a person when the room server says no. Never the server's own wording.
    static func roomErrorText(_ error: String) -> String {
        switch error {
        case "no-such-room", "bad-code":
            return "There is no room with that code. Check it with your partner and try again."
        case "room-full":
            return "Two people are already in that room. If you were in it a moment ago, wait a few seconds and try again; otherwise ask your partner to start a new room."
        case "server-full":
            return "The SameSofa server is busy right now. Try again in a few minutes."
        default:
            return "Something went wrong with the room. Try again; if it keeps happening, start a new room."
        }
    }

    private func startCall() {
        teardownCall()
        callsStarted += 1
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
            guard let self, self.reconnecting, !self.holdReconnectForTesting else { return }
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

    /// Host: how many films had to be converted (rewrapped or re-encoded) in this room; one found in the cache does not count.
    public private(set) var conversionsRun = 0
    /// Host: chunks of the current film handed to its channel so far (diagnostics, tests).
    public var chunksSent: Int { sender?.chunksSent ?? 0 }
    /// Host: the label of the channel the current film is sent on (diagnostics, tests).
    public var filmChannel: String? { filmChannelLabel }
    /// How many film channels this call has had so far (diagnostics, tests).
    public var filmChannelCount: Int { fileChannels.count }

    /// Test hook: a control message arrives as if the partner had sent it (late ones included).
    public func injectForTesting(_ message: ControlMessage) { handle(message) }

    /// Test hook: estimate the clock offset as 1.2.1 did (for measuring the difference).
    public var legacyClockEstimate = false

    /// Test hook: no restart after a drop, so the "Connection lost" card stays up (screenshots).
    public var holdReconnectForTesting = ProcessInfo.processInfo.environment["SAMESOFA_TEST_HOLD_RECONNECT"] == "1"

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
        nextSender?.stop()
        nextSender = nil
        nextChannelLabel = nil
        nextFetched = nil
        fileChannels.removeAll()
        filmChannelLabel = nil
        firstChannelUsed = false
        call?.close()
        call = nil
        remoteVideoTrack = nil
        localVideoTrack = nil
    }

    private func partnerLeft() {
        versionNote = nil
        partnerVersion = nil
        filmAnnounced = false
        turn.connectionReset()
        nextDeclined = nil
        if role == .host { receivedRanges = [] }
        dropGrace?.cancel()
        partnerPositionTimeout?.cancel()
        awaitingPartnerPosition = false
        reconnecting = false
        connectionFailed = false
        teardownCall()
        playback.resetRemote()
        if role == .host, let code {
            if sharedFilm != nil { transferFraction = 0; transferLine = "" }
            phase = .waitingForPartner(code: code)
        } else {
            phase = .ended("Your partner left.")
        }
    }

    // MARK: Control messages

    private func controlOpened(_ channel: RTCDataChannel) {
        Log.debug("\(role) control channel handed, state \(channel.readyState.rawValue)")
        let playback = self.playback
        let control = ControlChannel(channel: channel, now: { playback.localNow() }) { [weak self] message, at in self?.handle(message, receivedAt: at) }
        self.control = control
        control.send(.hello(role: role, protocolVersion: ControlMessage.protocolVersion))
        sendMediaState()
        if role == .host {
            // Nothing the guest says about a film counts until it has said which film it is on.
            turn.connectionReset()
            if sender != nil { playback.remoteBuffering(true, at: playback.currentTime) }
            sendFilmState()
            if let upNextName { control.send(.upNext(name: upNextName)) }
        } else {
            if let guestFilm { control.send(.filmAck(film: guestFilm)) }
            control.send(.buffering(playback.engine.localBuffering, position: playback.currentTime))
            // From the moment the channel is open: the first exchanges happen before the film starts to fill the link.
            control.onOpen = { [weak self, weak control] in
                guard let self, let control, control === self.control else { return }
                self.startClockSync()
            }
        }
    }

    /// Host: is what the guest says about "the film" about the current one?
    private var guestIsOnCurrentFilm: Bool { role == .guest || turn.guestIsOnCurrentFilm }

    private func refreshVersionNote() {
        let before = versionNote
        defer { if versionNote != before, let versionNote { Log.debug("\(role) version note: \(versionNote)") } }
        guard let partnerVersion else { versionNote = nil; return }
        switch ControlMessage.compatibility(with: partnerVersion) {
        case .same, .incompatible: versionNote = nil
        case .note(let text):
            // The host of an older guest is told what to do about it right now.
            versionNote = role == .host ? (ControlMessage.oldPartnerNote(theirs: partnerVersion, hasFilm: sender != nil) ?? text) : text
        }
    }

    /// `receivedAt`: this side's clock when the message arrived (before it waited for the main thread).
    private func handle(_ message: ControlMessage, receivedAt: Double? = nil) {
        if case .want = message {} else if case .ping = message {} else if case .pong = message {} else if case .heartbeat = message {} else {
            Log.debug("\(role) got \(message)")
        }
        switch message {
        case .hello(_, let version):
            Log.debug("\(role) partner speaks protocol \(version), this copy \(ControlMessage.protocolVersion)")
            if case .incompatible(let text) = ControlMessage.compatibility(with: version) {
                leave()
                phase = .ended(text)
                return
            }
            partnerVersion = version
            turn.partnerVersion = version
            refreshVersionNote()
        case .fileInfo(let info):
            guard role == .guest else { return }
            if receiver != nil, info.film == nil || info.film == guestFilm {
                // The film this copy is already on, announced again (a new connection): it may be on another channel now.
                if info.film != nil {
                    wantedChannel = info.channel ?? FileInfo.firstChannel
                    attachReceiver()
                }
                return
            }
            if let film = info.film {
                if film != guestFilm || receiver != nil { guestFilmChanged(to: film, seq: info.seq ?? playback.engine.timeline.seq + SyncEngine.filmGap) }
                control?.send(.filmAck(film: film))
            }
            receiveFilm(info)
        case .filmChanging(let film, let seq):
            guard role == .guest else { return }
            if film != guestFilm || receiver != nil { guestFilmChanged(to: film, seq: seq) }
            control?.send(.filmAck(film: film))
            choosingFilm = true
        case .noFilm(let film, let seq):
            guard role == .guest else { return }
            if film != guestFilm || receiver != nil || guestFilm == nil { guestFilmChanged(to: film, seq: seq) }
            control?.send(.filmAck(film: film))
            choosingFilm = false
            preparing = nil
        case .filmAck(let film):
            guard role == .host else { return }
            turn.confirm(film)
            prepareNext()
        case .upNext(let name):
            guard role == .guest else { return }
            upNextName = name
        case .prefetch(let info):
            guard role == .guest else { return }
            startPrefetching(info)
        case .prefetchStop:
            guard role == .guest else { return }
            stopPrefetching()
        case .prefetchWant(let chunks):
            guard role == .host else { return }
            nextSender?.request(chunks, urgent: false)
        case .prefetchProgress(let fraction):
            guard role == .host, nextSender != nil else { return }
            if fraction < 0 {
                // No room for it on the partner's Mac: it will simply be sent when its turn comes.
                nextDeclined = preparedNext?.id
                stopPrefetch()
            } else {
                nextFetched = fraction
            }
        case .nextIn(let seconds, let name):
            guard role == .guest else { return }
            nextCard = NextCard(name: name, deadline: Date().addingTimeInterval(max(0, seconds)))
        case .nextCancel:
            guard guestIsOnCurrentFilm else { return }
            dismissNext()
        case .filmHash(let film, let hash):
            guard role == .guest, film == guestFilm else { return }
            receiver?.setExpectedHash(hash)
        case .want(let chunks, let urgent, let reset):
            guard guestIsOnCurrentFilm else { return }
            sender?.request(chunks, urgent: urgent, reset: reset ?? false)
        case .progress(let fraction):
            guard guestIsOnCurrentFilm else { return }
            transferFraction = fraction
            if role == .host, fraction >= 1 {
                // The film has arrived: the next one may travel ahead now.
                if smoothedRate > 0 { lastFilmRate = smoothedRate }
                prepareNext()
            }
        case .have(let ranges):
            guard role == .host, guestIsOnCurrentFilm, let film = sharedFilm else { return }
            receivedRanges = ChunkMap.fractions(ranges: ranges, chunkCount: ChunkMap.chunkCount(fileSize: film.size, chunkSize: film.chunkSize))
        case .timeline(let timeline):
            guard guestIsOnCurrentFilm else { return }
            playback.receive(timeline)
        case .heartbeat(let timeline, let actual):
            playback.receiveHeartbeat(timeline, actual: actual)
        case .buffering(let buffering, let position):
            guard guestIsOnCurrentFilm else { return }
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
            let now = playback.localNow()
            control?.send(.pong(t0: t0, t1: receivedAt ?? now, hold: receivedAt.map { max(0, now - $0) }))
        case .pong(let t0, let t1, let hold):
            clock.add(t0: t0, t1: t1, t2: receivedAt ?? playback.localNow(), hold: hold ?? 0)
            playback.clockOffset = legacyClockEstimate ? clock.shortestRoundTripOffset : clock.offset
            clockRoundTrip = clock.bestRoundTrip ?? 0
        case .preparing(let fraction):
            if role == .guest, receiver == nil {
                choosingFilm = false
                preparing = Preparing(fraction: fraction, remuxOnly: false, speed: nil)
            }
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
        // The first one at once: before the film starts to fill the link.
        control?.send(.ping(t0: playback.localNow()))
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            count += 1
            // Quick burst at first, then once every 2 seconds.
            if count <= 12 || count % 8 == 0 {
                self.control?.send(.ping(t0: self.playback.localNow()))
            }
        }
    }

    // MARK: The film (guest)

    /// Guest: the host moved on to film number `film` (or to none). What
    /// there was of the film before goes; the call stays as it is.
    private func guestFilmChanged(to film: Int, seq: Int) {
        // What was being fetched ahead is handed back first: it may be the very film that starts now.
        stopPrefetching()
        if let receiver {
            // Lets go of the film's channel too; whatever still arrives on it is for nobody.
            receiver.cancel()
            fileChannels[wantedChannel] = nil
        }
        receiver = nil
        clearFilmState()
        guestFilm = film
        playback.startOver(at: seq)
    }

    private func attachReceiver() {
        guard let receiver, let channel = fileChannels[wantedChannel], receiver.attachedChannel !== channel else { return }
        receiver.attach(channel)
    }

    private func receiveFilm(_ info: FileInfo) {
        // A description that makes no sense is not acted on.
        guard info.size > 0, info.chunkSize >= 1024, info.chunkSize <= 1 << 22 else {
            Log.debug("guest: film description not usable")
            filmNotice = "That film couldn't be opened on this Mac. Ask your partner to choose it again."
            return
        }
        do {
            let receiver = try FileReceiver(info: info, cache: filmCache)
            self.receiver = receiver
            choosingFilm = false
            preparing = nil
            filmNotice = nil
            sharedFilm = info
            filmName = (info.name as NSString).deletingPathExtension
            wantedChannel = info.channel ?? FileInfo.firstChannel
            // Until the first part has arrived this side counts as buffering, and says so.
            playback.startBuffering()
            if info.film != nil { control?.send(.buffering(true, position: 0)) }
            receiver.requestChunks = { [weak self, weak receiver] chunks, urgent, jump in
                guard let self, let receiver, receiver === self.receiver else { return }
                self.control?.send(.want(chunks: chunks, urgent: urgent, reset: jump ? true : nil))
            }
            receiver.onProgress = { [weak self, weak receiver] fraction in
                guard let self, let receiver, receiver === self.receiver else { return }
                self.transferFraction = fraction
                self.control?.send(.progress(fraction: fraction))
            }
            receiver.onRanges = { [weak self, weak receiver] ranges, count in
                guard let self, let receiver, receiver === self.receiver else { return }
                self.receivedRanges = ChunkMap.fractions(ranges: ranges, chunkCount: count)
                self.control?.send(.have(ranges: ranges))
            }
            // What is here from an earlier session shows at once, on both sides.
            if receiver.resumedChunks > 0 { receiver.reportNow() }
            attachReceiver()
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
            // The room goes on; only this film cannot be watched here.
            filmNotice = "There isn't enough room on this Mac for the film. Free up some space, then ask your partner to choose it again."
        }
    }
}

extension Party: CallSessionDelegate {
    public func call(_ call: CallSession, wantsToSignal payload: [String: Any]) {
        signaling.signal(payload)
    }

    public func call(_ call: CallSession, logged state: String) {
        guard call === self.call else { return }
        connectionLog.append("call \(callsStarted): \(state)")
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
        guard call === self.call else { return }
        controlOpened(channel)
    }

    public func call(_ call: CallSession, fileChannelOpened channel: RTCDataChannel) {
        guard call === self.call else { return }
        Log.debug("\(role) film channel \(channel.label) handed, state \(channel.readyState.rawValue)")
        fileChannels[channel.label] = channel
        if role == .host {
            if sender != nil, filmChannelLabel == nil { assignFilmChannel() }
        } else if channel.label == wantedChannel {
            attachReceiver()
        } else if channel.label == prefetchChannel {
            prefetcher?.attach(channel)
        }
    }

    public func call(_ call: CallSession, remoteVideoTrack track: RTCVideoTrack) {
        guard call === self.call else { return }
        remoteVideoTrack = track
    }
}

/// Wraps the "control" data channel: JSON messages, queued until it opens.
final class ControlChannel: NSObject, RTCDataChannelDelegate {
    private let channel: RTCDataChannel
    private let now: () -> Double
    private let onMessage: (ControlMessage, Double) -> Void
    private var queue: [ControlMessage] = []
    private var announcedOpen = false
    /// Called once, on the main queue, when the channel can carry messages (at once if it already can).
    var onOpen: (() -> Void)? { didSet { DispatchQueue.main.async { self.noteOpen() } } }

    /// `now`: this side's clock; read on WebRTC's thread the moment a message arrives.
    init(channel: RTCDataChannel, now: @escaping () -> Double, onMessage: @escaping (ControlMessage, Double) -> Void) {
        self.channel = channel
        self.now = now
        self.onMessage = onMessage
        super.init()
        ChannelRelay.attach(channel, to: self)
    }

    private func noteOpen() {
        guard !announcedOpen, channel.readyState == .open, let onOpen else { return }
        announcedOpen = true
        onOpen()
    }

    /// Test hook (SAMESOFA_TEST_CONTROL_DELAY_MS): every message leaves this much later, in
    /// order, as it would arrive over a real network instead of loopback.
    private static let testDelay: Double = (ProcessInfo.processInfo.environment["SAMESOFA_TEST_CONTROL_DELAY_MS"].flatMap(Double.init) ?? 0) / 1000
    private var delayed = 0

    func send(_ message: ControlMessage) {
        guard Self.testDelay > 0 else {
            queue.append(message)
            flush()
            return
        }
        delayed += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.testDelay) {
            self.delayed -= 1
            self.queue.append(message)
            self.flush()
        }
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
        DispatchQueue.main.async {
            self.flush()
            self.noteOpen()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let at = now()
        guard let message = ControlMessage.decode(buffer.data) else { return }
        DispatchQueue.main.async { self.onMessage(message, at) }
    }
}
