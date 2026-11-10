import AVFoundation
import Combine
import Foundation
import SameSofaCore

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
    private var observers: [NSKeyValueObservation] = []

    public init(role: PeerRole, hub: AudioHub) {
        engine = SyncEngine(role: role)
        self.hub = hub
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
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
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        item.preferredForwardBufferDuration = 20
        player.replaceCurrentItem(with: item)
        observers = [item.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async { if item.status == .readyToPlay { self?.isLoaded = true; self?.apply() } }
        }]
        Task { [weak self] in
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            await MainActor.run {
                guard let self else { return }
                self.duration = duration.isFinite ? duration : 0
                self.hasVideo = !videoTracks.isEmpty
                if let track = audioTracks.first, let mix = FilmAudioTap.audioMix(for: track, hub: self.hub) {
                    item.audioMix = mix
                }
                self.hub.start()
            }
        }
    }

    public func unload() {
        player.pause()
        player.replaceCurrentItem(with: nil)
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
    }

    public func skip(by delta: Double) { seek(to: engine.targetPosition(at: sharedNow) + delta) }

    // MARK: From the other side

    func receive(_ timeline: Timeline) {
        if engine.receive(timeline) { apply() }
    }

    func receiveHeartbeat(_ timeline: Timeline, actual: Double) {
        remoteActual = (actual, sharedNow)
        receive(timeline)
    }

    func remoteBuffering(_ buffering: Bool) {
        if buffering { holdCount += 1 }
        if let restart = engine.setRemoteBuffering(buffering, now: sharedNow, actualPosition: currentTime) {
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
        guard engine.effectivePlaying else {
            pendingStartUntil = 0
            player.rate = 0
            if abs(currentTime - target) > 0.04 { seekPrecisely(to: target, thenPlay: false) }
            return
        }
        let anchorLocal = engine.timeline.anchor - clockOffset
        let local = localNow()
        if anchorLocal > local + 0.03 {
            // Scheduled start: be at the right frame and start at the same instant as the other side.
            let timeline = engine.timeline
            player.rate = 0
            pendingStartUntil = anchorLocal + 0.3
            seekPrecisely(to: timeline.position, thenPlay: false) { [weak self] in
                guard let self, self.engine.timeline == timeline else { return }
                let hostTime = CMTime(seconds: anchorLocal - self.testClockSkew, preferredTimescale: 1_000_000_000)
                self.player.setRate(1, time: CMTime(seconds: timeline.position, preferredTimescale: 600), atHostTime: hostTime)
            }
        } else if abs(currentTime - target) > 0.5 {
            seekPrecisely(to: target + 0.15, thenPlay: true)
        } else {
            player.rate = 1
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
                if let completion { completion() } else if thenPlay, self.engine.effectivePlaying { self.player.rate = 1 }
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
        switch engine.correction(actualPosition: actual, now: now) {
        case .none(let rate):
            if Float(rate) != player.rate { player.rate = Float(rate) }
        case .adjustRate(let rate):
            player.rate = Float(rate)
        case .seek(let target):
            guard local - lastSeekAt > 1.5 else { return }
            if engine.effectivePlaying {
                seekPrecisely(to: target + 0.15, thenPlay: true)
            } else {
                seekPrecisely(to: target, thenPlay: false)
            }
        }
        publishState()
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
                send?(.buffering(true))
                apply()
            }
        } else {
            let enough = ready && (hasEnoughAhead?(actual) ?? true)
            if enough {
                stallWatch = nil
                let restart = engine.setLocalBuffering(false, now: now, actualPosition: actual)
                send?(.buffering(false))
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
