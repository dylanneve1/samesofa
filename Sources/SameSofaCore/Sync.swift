import Foundation

/// NTP-style estimate of the offset between this machine's clock and the
/// host's clock. The guest pings, the host replies with its own time; the
/// sample with the smallest round trip in a recent window wins.
public struct ClockSync: Sendable {
    public struct Sample: Sendable {
        public var offset: Double
        public var roundTrip: Double
    }

    private var samples: [Sample] = []
    public var windowSize = 16

    public init() {}

    /// t0: local send time, t1: host time in the reply, t2: local receive time.
    public mutating func add(t0: Double, t1: Double, t2: Double) {
        let rtt = max(0, t2 - t0)
        let offset = t1 - (t0 + t2) / 2
        samples.append(Sample(offset: offset, roundTrip: rtt))
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
    }

    public var hasEstimate: Bool { !samples.isEmpty }

    /// host clock ≈ local clock + offset
    public var offset: Double {
        samples.min(by: { $0.roundTrip < $1.roundTrip })?.offset ?? 0
    }

    public var bestRoundTrip: Double? { samples.map(\.roundTrip).min() }
}

/// What the player should do to follow the shared timeline.
public enum PlayerCorrection: Equatable, Sendable {
    /// Leave the player alone (and at normal speed).
    case none(rate: Double)
    /// Nudge the speed slightly to close a small gap without a visible jump.
    case adjustRate(Double)
    /// Too far off: jump to this position.
    case seek(to: Double)
}

/// The shared playback state machine. Pure logic: the caller supplies the
/// shared-clock time and the player's actual position, and applies whatever
/// comes back. Both sides run one of these.
public struct SyncEngine: Sendable {
    public let role: PeerRole
    public private(set) var timeline: Timeline
    /// Reasons to hold playback even though someone pressed play.
    public private(set) var localBuffering = false
    public private(set) var remoteBuffering = false

    // Tuning. Gaps under `deadband` are ignored; up to `seekThreshold` they are
    // closed by playing a little faster or slower; beyond that we seek.
    // The speed change is kept between `minRateDelta` and `maxRateDelta` (at
    // most 1 %, a sixth of a semitone, and usually far less) so that it cannot
    // be heard, and once started it continues down to `settleBand` so the
    // speed does not flap around the edge of the deadband.
    public var deadband = 0.06
    public var settleBand = 0.015
    public var seekThreshold = 0.35
    public var maxRateDelta = 0.01
    public var minRateDelta = 0.002
    /// Rate gain: seconds of drift -> rate offset.
    public var gain = 0.1
    /// When starting from a pause, schedule the start this far in the future
    /// so the message reaches the other side before the film starts.
    public var startLead = 0.35

    public init(role: PeerRole) {
        self.role = role
        // The guest starts one behind so the host's first heartbeat is adopted.
        timeline = Timeline(playing: false, position: 0, anchor: 0, seq: role == .host ? 0 : -1, origin: .host)
    }

    /// Playback should actually be moving right now.
    public var effectivePlaying: Bool { timeline.playing && !localBuffering && !remoteBuffering && !awaitingRestart }
    /// A hold has cleared on the guest, and it is waiting for the host to
    /// schedule the common restart.
    public var awaitingRestart: Bool { timeline.playing && timeline.anchor == .greatestFiniteMagnitude }
    public var isHeld: Bool { timeline.playing && (localBuffering || remoteBuffering || awaitingRestart) }

    private mutating func next(playing: Bool, position: Double, anchor: Double) -> Timeline {
        timeline = Timeline(playing: playing, position: max(0, position), anchor: anchor,
                            seq: timeline.seq + 1, origin: role)
        return timeline
    }

    // MARK: Local actions. Each returns the timeline to send to the other side.

    public mutating func play(now: Double) -> Timeline {
        let here = timeline.expectedPosition(at: now)
        return next(playing: true, position: here, anchor: now + startLead)
    }

    public mutating func pause(now: Double, at position: Double? = nil) -> Timeline {
        let here = position ?? timeline.expectedPosition(at: now)
        return next(playing: false, position: here, anchor: now)
    }

    public mutating func seek(to position: Double, now: Double) -> Timeline {
        let anchor = timeline.playing ? now + startLead : now
        return next(playing: timeline.playing, position: position, anchor: anchor)
    }

    /// Host only: its player is not where the timeline says (it slipped).
    /// The timeline moves to the player, so the host, whose sound nobody
    /// should hear change speed, never has to nudge; the guest follows.
    public mutating func reanchor(now: Double, actualPosition: Double) -> Timeline {
        next(playing: timeline.playing, position: actualPosition, anchor: now)
    }

    // MARK: Remote input

    /// Applies a timeline from the other side. Returns true if it was newer and adopted.
    @discardableResult
    public mutating func receive(_ remote: Timeline) -> Bool {
        guard remote.isNewer(than: timeline) else { return false }
        timeline = remote
        return true
    }

    /// Local player starved (or recovered). Returns the timeline to send when
    /// recovery means everyone should restart together, else nil.
    public mutating func setLocalBuffering(_ buffering: Bool, now: Double, actualPosition: Double) -> Timeline? {
        guard buffering != localBuffering else { return nil }
        localBuffering = buffering
        return holdChanged(now: now, actualPosition: actualPosition)
    }

    public mutating func setRemoteBuffering(_ buffering: Bool, now: Double, actualPosition: Double) -> Timeline? {
        guard buffering != remoteBuffering else { return nil }
        remoteBuffering = buffering
        return holdChanged(now: now, actualPosition: actualPosition)
    }

    /// While held, the timeline is frozen where the film stopped. When the
    /// hold clears, the host (only the host, to avoid two competing restarts)
    /// schedules a fresh start from that point.
    private mutating func holdChanged(now: Double, actualPosition: Double) -> Timeline? {
        guard timeline.playing else { return nil }
        if localBuffering || remoteBuffering {
            // Freeze the anchor at the current point so expectedPosition stops advancing.
            let frozen = min(actualPosition, timeline.expectedPosition(at: now))
            timeline = Timeline(playing: true, position: frozen, anchor: .greatestFiniteMagnitude,
                                seq: timeline.seq, origin: timeline.origin)
            return nil
        }
        guard role == .host else { return nil }
        return next(playing: true, position: timeline.position, anchor: now + startLead)
    }

    /// While held: the other side's film stopped earlier than ours (its
    /// connection went first). The restart then happens from there, so that
    /// nobody misses anything.
    public mutating func lowerHeldPosition(to position: Double) {
        guard isHeld, position < timeline.position else { return }
        timeline = Timeline(playing: true, position: max(0, position), anchor: .greatestFiniteMagnitude,
                            seq: timeline.seq, origin: timeline.origin)
    }

    /// Position the player should show at `now` (frozen while held).
    public func targetPosition(at now: Double) -> Double {
        if isHeld { return timeline.position }
        return timeline.expectedPosition(at: now)
    }

    /// Compares the player's actual position with the timeline.
    /// `nudging`: the previous answer was `.adjustRate` (a correction is under way).
    public func correction(actualPosition: Double, now: Double, nudging: Bool = false) -> PlayerCorrection {
        let target = targetPosition(at: now)
        guard effectivePlaying, now >= timeline.anchor else {
            return abs(actualPosition - target) > 0.04 ? .seek(to: target) : .none(rate: 0)
        }
        let drift = actualPosition - target // positive: we are ahead
        if abs(drift) >= seekThreshold { return .seek(to: target) }
        if abs(drift) <= (nudging ? settleBand : deadband) { return .none(rate: 1) }
        let delta = min(maxRateDelta, max(minRateDelta, abs(drift) * gain))
        return .adjustRate(drift > 0 ? 1 - delta : 1 + delta)
    }
}
