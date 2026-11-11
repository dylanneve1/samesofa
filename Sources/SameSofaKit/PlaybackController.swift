import AVFoundation
import Combine
import Foundation
import SameSofaCore

/// Test hook: every buffer of film sound exactly as the player goes on to
/// play it (buffers, frames, channels, position in frames if known).
public typealias FilmAudioMonitor = (UnsafeMutableAudioBufferListPointer, Int, Int, Int64?) -> Void

/// Drives one AVPlayer so that it follows the shared timeline in a SyncEngine.
/// Lives on the main thread.
public final class PlaybackController: ObservableObject {
    public let player = AVPlayer()
    @Published public private(set) var position: Double = 0
    @Published public private(set) var duration: Double = 0
    /// Someone pressed play (even if we are currently held for buffering).
    @Published public private(set) var intendsToPlay = false
    /// Paused because one side is still buffering.
    @Published public private(set) var isHeld = false
    @Published public private(set) var localBuffering = false
    @Published public private(set) var isLoaded = false
    @Published public private(set) var hasVideo = true
    /// The film carries a text subtitle track (from MKV or a .srt, converted to MP4).
    @Published public private(set) var hasSubtitles = false
    @Published public private(set) var subtitlesOn = false
    private var subtitleGroup: AVMediaSelectionGroup?
    /// What is being played (codecs, sizes, bit rates), for the quality readout.
    @Published public private(set) var quality = PlaybackQuality()
    /// Test hook, set before `load`.
    public var filmAudioMonitor: FilmAudioMonitor?
    /// How often the playback speed was nudged to stay in sync (diagnostics).
    public private(set) var nudgeCount = 0
    private var nudging = false
    /// The film's frame rate (0 if unknown), for matching the display to it.
    @Published public private(set) var frameRate = 0.0
    /// Let the system apply spatial audio (Dolby Atmos, AirPods) instead of
    /// a plain downmix. Set before `load`.
    public var systemSpatialAudio = false
    /// How often an item's sound was set up (must be once per film) and how
    /// often the playback speed was changed: both make the system rebuild its
    /// audio pipeline, so tests keep an eye on them.
    public private(set) var audioSetupCount = 0
    public private(set) var rateChangeCount = 0
    /// Host: how often the timeline was moved to the player instead of nudging.
    public private(set) var reanchorCount = 0
    private var loadGeneration = 0
    /// Makes the listening tap for the current film, until it has been attached.
    private var listening: (() -> AVAudioMix?)?
    private var hostSlipTicks = 0

    private func setRate(_ rate: Float) {
        guard player.rate != rate else { return }
        player.rate = rate
        rateChangeCount += 1
    }

    public private(set) var engine: SyncEngine
    private let hub: AudioHub
    /// Shared clock = local clock + offset (0 on the host).
    public internal(set) var clockOffset: Double = 0
    var send: ((ControlMessage) -> Void)?
    /// Guest only: is there enough film downloaded ahead of `position`?
    var hasEnoughAhead: ((Double) -> Bool)?
    /// Last position the other side reported (heartbeat), for diagnostics/tests.
    public private(set) var remoteActual: (position: Double, sharedTime: Double)?

    private var timer: Timer?
    private var seeking = false
    private var pendingStartUntil: Double = 0
    private var lastSeekAt: Double = -10
    private var lastCorrectionAt: Double = 0
    private var stallWatch: (position: Double, since: Double)?
    private var lastHeartbeat: Double = 0
    private var correctionSeeks: [Double] = []
    private var observers: [NSKeyValueObservation] = []

    public init(role: PeerRole, hub: AudioHub) {
        engine = SyncEngine(role: role)
        self.hub = hub
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        // The film's sound goes straight from the player to the normal sound
        // output; nothing of ours sits in between.
        player.volume = hub.filmVolume
        if hub.mode == .synthetic { player.isMuted = true }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    deinit { timer?.invalidate() }

    public static func hostClockNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    /// Test hook: pretend this machine's clock is off by this many seconds,
    /// to exercise clock synchronisation inside one process.
    public var testClockSkew: Double = 0
    /// This side's clock (seconds).
    public func localNow() -> Double { Self.hostClockNow() + testClockSkew }
    public var sharedNow: Double { localNow() + clockOffset }
    public private(set) var holdCount = 0

    // MARK: Loading

    public func load(asset: AVURLAsset) {
        isLoaded = false
        loadGeneration += 1
        let generation = loadGeneration
        Task { [weak self] in
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            let quality = await PlaybackQuality.describe(video: videoTracks.first, audio: audioTracks.first)
            var roles: [ChannelRole]?
            if let format = (try? await audioTracks.first?.load(.formatDescriptions))?.first {
                roles = ChannelLayoutReader.roles(for: format)
            }
            let channelRoles = roles
            let frameRate = Double((try? await videoTracks.first?.load(.nominalFrameRate)) ?? 0)
            await MainActor.run {
                guard let self, self.loadGeneration == generation else { return }
                // Everything about the item's sound is decided here, once,
                // before the player gets the item: changing it later makes the
                // system rebuild its audio pipeline (audible with Dolby
                // Atmos and other spatial formats).
                let item = AVPlayerItem(asset: asset)
                // Plain resampling: bit-transparent at normal speed, and free of
                // the artefacts of time stretching during a guest's rare, tiny sync nudges.
                item.audioTimePitchAlgorithm = .varispeed
                item.preferredForwardBufferDuration = 20
                if self.systemSpatialAudio {
                    // The system decides (Dolby Atmos, spatial audio with AirPods...).
                    // Nothing listens in, so the film cannot be removed from the microphone.
                    self.hub.setFilmTimebase(nil)
                } else {
                    // A plain stereo or multichannel signal, folded down by the
                    // system when the output has fewer channels.
                    item.allowedAudioSpatializationFormats = []
                    // With speakers, listen in (a copy only: the sound itself is
                    // not touched) so the film can be removed from the
                    // microphone during a call. With headphones nothing is
                    // attached; should the output change to speakers later,
                    // `soundOutputChanged` attaches it then.
                    self.listening = audioTracks.first.map { track in
                        { [hub = self.hub, monitor = self.filmAudioMonitor] in FilmAudioTap.audioMix(for: track, roles: channelRoles, hub: hub, monitor: monitor) }
                    }
                    if self.hub.wantsFilmReference, let mix = self.listening?() {
                        item.audioMix = mix
                        self.listening = nil
                        self.hub.setFilmTimebase(item.timebase)
                    } else {
                        self.hub.setFilmTimebase(nil)
                    }
                }
                self.audioSetupCount += 1
                self.subtitleGroup = legible
                self.hasSubtitles = !(legible?.options.isEmpty ?? true)
                // Off by default; the toggle in the controls turns them on.
                if let legible { item.select(nil, in: legible) }
                self.subtitlesOn = false
                self.duration = duration.isFinite ? duration : 0
                self.hasVideo = !videoTracks.isEmpty
                self.quality = quality
                self.frameRate = frameRate
                self.observers = [item.observe(\.status) { [weak self] item, _ in
                    DispatchQueue.main.async { if item.status == .readyToPlay { self?.isLoaded = true; self?.apply() } }
                }]
                self.player.replaceCurrentItem(with: item)
            }
        }
    }

    /// The sound output or the headphones setting changed. If the film now
    /// has to be removed from the microphone and nothing listens to it yet,
    /// start listening (once; it is never removed again for this film).
    public func soundOutputChanged() {
        guard hub.wantsFilmReference, let item = player.currentItem, item.audioMix == nil, let mix = listening?() else { return }
        listening = nil
        item.audioMix = mix
        audioSetupCount += 1
        hub.setFilmTimebase(item.timebase)
    }

    /// Shows or hides the film's subtitles (each side chooses for itself).
    public func setSubtitles(_ on: Bool) {
        guard let group = subtitleGroup, let item = player.currentItem else { return }
        item.select(on ? group.options.first : nil, in: group)
        subtitlesOn = on && !group.options.isEmpty
    }

    /// The subtitle option the player is showing, if any (for tests).
    public var selectedSubtitle: AVMediaSelectionOption? {
        guard let group = subtitleGroup else { return nil }
        return player.currentItem?.currentMediaSelection.selectedMediaOption(in: group)
    }

    public func unload() {
        hasSubtitles = false
        subtitlesOn = false
        subtitleGroup = nil
        loadGeneration += 1
        listening = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        hub.setFilmTimebase(nil)
        frameRate = 0
        quality = PlaybackQuality()
        observers = []
        isLoaded = false
    }

    // MARK: User actions (from either side's UI)

    public func togglePlay() { intendsToPlay ? pause() : play() }

    public func play() {
        let t = engine.play(now: sharedNow)
        send?(.timeline(t))
        apply()
    }

    public func pause() {
        let t = engine.pause(now: sharedNow, at: currentTime)
        send?(.timeline(t))
        apply()
    }

    public func seek(to seconds: Double) {
        let clamped = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        let t = engine.seek(to: clamped, now: sharedNow)
        send?(.timeline(t))
        position = clamped
        apply()
        holdIfUnbuffered(at: clamped)
    }

    public func skip(by delta: Double) { seek(to: engine.targetPosition(at: sharedNow) + delta) }

    // MARK: From the other side

    func receive(_ timeline: Timeline) {
        if engine.receive(timeline) {
            apply()
            holdIfUnbuffered(at: engine.targetPosition(at: sharedNow))
        }
    }

    func receiveHeartbeat(_ timeline: Timeline, actual: Double) {
        remoteActual = (actual, sharedNow)
        receive(timeline)
    }

    func remoteBuffering(_ buffering: Bool, at remotePosition: Double) {
        if buffering { holdCount += 1 }
        // Resume from whichever side stopped earlier, so nobody misses a moment.
        let position = buffering ? min(currentTime, remotePosition) : currentTime
        if let restart = engine.setRemoteBuffering(buffering, now: sharedNow, actualPosition: position) {
            send?(.timeline(restart))
        }
        apply()
    }

    /// Clears hold state, e.g. when the other person leaves.
    func resetRemote() {
        _ = engine.setRemoteBuffering(false, now: sharedNow, actualPosition: currentTime)
        apply()
    }

    // MARK: Applying the timeline

    public var currentTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    private func publishState() {
        intendsToPlay = engine.timeline.playing
        isHeld = engine.isHeld
        localBuffering = engine.localBuffering
    }

    func apply() {
        publishState()
        guard player.currentItem != nil else { return }
        let now = sharedNow
        let target = engine.targetPosition(at: now)
        Log.debug("\(engine.role) apply playing=\(engine.timeline.playing) effective=\(engine.effectivePlaying) held=\(engine.isHeld) target=\(String(format: "%.2f", target)) actual=\(String(format: "%.2f", currentTime)) anchorIn=\(String(format: "%.2f", engine.timeline.anchor - now))")
        guard engine.effectivePlaying else {
            pendingStartUntil = 0
            setRate(0)
            if abs(currentTime - target) > 0.04 { seekPrecisely(to: target, thenPlay: false) }
            return
        }
        let anchorLocal = engine.timeline.anchor - clockOffset
        let local = localNow()
        if anchorLocal > local + 0.03 {
            // Scheduled start: be at the right frame and start at the same instant as the other side.
            startSynced(atLocal: anchorLocal)
        } else if abs(currentTime - target) > 0.5 {
            startSynced(atLocal: local + 0.5)
        } else {
            setRate(1)
        }
    }

    /// Seeks to wherever the timeline will be at local time `startLocal` and
    /// starts playing exactly then. Precise seeks in films with sparse
    /// keyframes can be slow; if the seek finishes too late, it tries again
    /// with a longer lead instead of starting behind.
    private func startSynced(atLocal startLocal: Double, attempt: Int = 0) {
        let timeline = engine.timeline
        let startShared = startLocal + clockOffset
        let position = engine.targetPosition(at: startShared)
        setRate(0)
        pendingStartUntil = startLocal + 0.4
        let began = localNow()
        seekPrecisely(to: position, thenPlay: false) { [weak self] in
            guard let self, self.engine.timeline == timeline, self.engine.effectivePlaying else { return }
            let local = self.localNow()
            Log.debug("\(self.engine.role) seek done after \(String(format: "%.2f", local - began)) s, start in \(String(format: "%.2f", startLocal - local)) s")
            if local > startLocal - 0.01 {
                guard attempt < 4 else { self.setRate(1); return }
                let took = local - began
                self.startSynced(atLocal: local + min(3, max(0.5, took * 1.5)), attempt: attempt + 1)
                return
            }
            let hostTime = CMTime(seconds: startLocal - self.testClockSkew, preferredTimescale: 1_000_000_000)
            self.player.setRate(1, time: CMTime(seconds: position, preferredTimescale: 600), atHostTime: hostTime)
            self.rateChangeCount += 1
        }
    }

    private func seekPrecisely(to seconds: Double, thenPlay: Bool, completion: (() -> Void)? = nil) {
        seeking = true
        lastSeekAt = localNow()
        position = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seeking = false
                guard finished else { return }
                if let completion { completion() } else if thenPlay, self.engine.effectivePlaying { self.setRate(1) }
                self.stallWatch = nil
            }
        }
    }

    // MARK: Periodic work

    private func tick() {
        let now = sharedNow
        let local = localNow()
        let actual = currentTime
        if !seeking { position = actual }
        guard player.currentItem != nil else { return }

        // Host heartbeat.
        if engine.role == .host, local - lastHeartbeat >= 1 {
            lastHeartbeat = local
            send?(.heartbeat(engine.timeline, actualPosition: actual))
        }

        checkBuffering(now: now, local: local, actual: actual)

        // Drift correction, at most every half second and not mid-seek/start.
        guard !seeking, local > pendingStartUntil, local - lastCorrectionAt >= 0.5 else { return }
        lastCorrectionAt = local
        switch engine.correction(actualPosition: actual, now: now, nudging: nudging) {
        case .none(let rate):
            nudging = false
            hostSlipTicks = 0
            setRate(Float(rate))
        case .adjustRate(let rate):
            if engine.role == .host {
                // The host is the reference and never changes speed. If its
                // player has slipped (and stays off for a second), the
                // timeline moves to the player and the guest follows.
                hostSlipTicks += 1
                if hostSlipTicks >= 2 {
                    hostSlipTicks = 0
                    reanchorCount += 1
                    send?(.timeline(engine.reanchor(now: now, actualPosition: actual)))
                }
            } else if !nudging || (rate > 1) != (player.rate > 1) {
                // One speed for the whole correction, chosen at its start and
                // held until the gap is closed: every change of speed is a
                // small disturbance in itself.
                nudgeCount += 1
                nudging = true
                setRate(Float(rate))
            }
        case .seek(let target):
            nudging = false
            hostSlipTicks = 0
            guard local - lastSeekAt > 1.5 else { return }
            if engine.effectivePlaying {
                // Falling behind because the film hasn't arrived yet is buffering,
                // not drift: seeking forward into missing data would just stall again.
                correctionSeeks = correctionSeeks.filter { local - $0 < 8 } + [local]
                if !(hasEnoughAhead?(target) ?? true) || correctionSeeks.count >= 3 {
                    correctionSeeks.removeAll()
                    holdCount += 1
                    _ = engine.setLocalBuffering(true, now: now, actualPosition: actual)
                    send?(.buffering(true, position: actual))
                    apply()
                    return
                }
                startSynced(atLocal: local + 0.5)
            } else {
                seekPrecisely(to: target, thenPlay: false)
            }
        }
        publishState()
    }

    /// A seek to a place the film hasn't reached yet: show buffering at once (both
    /// sides pause together) and start fetching there, instead of waiting to notice a stall.
    private func holdIfUnbuffered(at target: Double) {
        guard let hasEnoughAhead, !engine.localBuffering, player.currentItem != nil, abs(target - currentTime) > 2, !hasEnoughAhead(target) else { return }
        holdCount += 1
        _ = engine.setLocalBuffering(true, now: sharedNow, actualPosition: target)
        send?(.buffering(true, position: target))
        seekPrecisely(to: target, thenPlay: false)
        apply()
    }

    private func checkBuffering(now: Double, local: Double, actual: Double) {
        let item = player.currentItem
        let ready = item?.status == .readyToPlay
        if !engine.localBuffering {
            var starved = !ready && engine.role == .guest
            if engine.effectivePlaying, !seeking, local > pendingStartUntil {
                if let watch = stallWatch, abs(actual - watch.position) < 0.05 {
                    if local - watch.since > 1.0, !(hasEnoughAhead?(actual) ?? true) || item?.isPlaybackBufferEmpty == true { starved = true }
                    if local - watch.since > 3.0 { starved = true }
                } else {
                    stallWatch = (actual, local)
                }
            } else {
                stallWatch = nil
            }
            if starved {
                holdCount += 1
                _ = engine.setLocalBuffering(true, now: now, actualPosition: actual)
                send?(.buffering(true, position: actual))
                apply()
            }
        } else {
            let enough = ready && (hasEnoughAhead?(actual) ?? true)
            if enough {
                stallWatch = nil
                let restart = engine.setLocalBuffering(false, now: now, actualPosition: actual)
                send?(.buffering(false, position: actual))
                if let restart { send?(.timeline(restart)) }
                apply()
            }
        }
    }

    /// Guest: before the film is ready it counts as buffering.
    func startBuffering() {
        _ = engine.setLocalBuffering(true, now: sharedNow, actualPosition: 0)
        publishState()
    }
}
