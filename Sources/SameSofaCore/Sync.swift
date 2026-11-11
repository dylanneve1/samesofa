import Foundation

/// NTP-style estimate of the offset between this machine's clock and the
/// host's clock. The guest pings, the host replies with its own time.
///
/// Each exchange gives two one-way measurements: "host clock at arrival
/// minus guest clock at sending" (the offset plus the delay on the way
/// there) and "guest clock at arrival minus host clock at sending" (the
/// delay on the way back minus the offset). Delay only ever adds, so the
/// smallest of each kind over the recent exchanges is the cleanest, and the
/// two smallest need not come from the same exchange: while the film fills
/// the link in one direction, a ping that got through quickly and a reply
/// that got through quickly are enough. (Taking the one exchange with the
/// shortest round trip, as before 1.3, is off by half the difference between
/// its two directions, which under a one-sided load is half its round trip.)
public struct ClockSync: Sendable {
    public struct Sample: Sendable {
        /// Host clock at arrival of the ping minus guest clock at sending it.
        public var there: Double
        /// Guest clock at arrival of the reply minus host clock at sending it.
        public var back: Double
        public var roundTrip: Double
        /// The single-exchange estimate, for comparison.
        public var offset: Double { (there - back) / 2 }
    }

    private var samples: [Sample] = []
    public var windowSize = 30

    public init() {}

    /// t0: local send time, t1: host time at arrival, t2: local receive time.
    /// `hold`: how long the host kept the ping before answering (0 if it does not say).
    public mutating func add(t0: Double, t1: Double, t2: Double, hold: Double = 0) {
        let hold = max(0, min(hold, max(0, t2 - t0)))
        samples.append(Sample(there: t1 - t0, back: t2 - (t1 + hold), roundTrip: max(0, t2 - t0 - hold)))
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
    }

    public var hasEstimate: Bool { !samples.isEmpty }

    /// host clock ≈ local clock + offset
    public var offset: Double {
        guard let there = samples.map(\.there).min(), let back = samples.map(\.back).min() else { return 0 }
        return (there - back) / 2
    }

    /// The estimate before 1.3: the exchange with the shortest round trip (tests compare the two).
    public var shortestRoundTripOffset: Double {
        samples.min(by: { $0.roundTrip < $1.roundTrip })?.offset ?? 0
    }

    public var bestRoundTrip: Double? { samples.map(\.roundTrip).min() }

    /// How far off the estimate can be at most: half of what the two best one-way measurements add up to.
    public var uncertainty: Double? {
        guard let there = samples.map(\.there).min(), let back = samples.map(\.back).min() else { return nil }
        return max(0, there + back) / 2
    }
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

    // MARK: A new film in the same room

    /// Sequence numbers jump by this much when the film changes (or is
    /// closed), so nothing that was sent for the film before, however late
    /// it arrives, can count as newer than the new film's timeline.
    public static let filmGap = 1000

    /// Host: a new film (or none) begins. Paused at the start; the numbering
    /// goes on upwards. `partnerLoading`: a partner is here and has to
    /// fetch the film first, so it counts as buffering until it says otherwise.
    @discardableResult
    public mutating func startOver(now: Double, partnerLoading: Bool = false) -> Timeline {
        localBuffering = false
        remoteBuffering = partnerLoading
        lastCommand = nil
        overridden = nil
        timeline = Timeline(playing: false, position: 0, anchor: now, seq: max(0, timeline.seq) + Self.filmGap, origin: .host)
        return timeline
    }

    /// Guest: the host announced a new film (or none) whose timeline starts at `seq`.
    public mutating func startOver(at seq: Int) {
        localBuffering = false
        remoteBuffering = false
        lastCommand = nil
        overridden = nil
        timeline = Timeline(playing: false, position: 0, anchor: 0, seq: seq, origin: .host)
    }

    // MARK: Commands that lose a tie

    /// What a person asked for (as opposed to the timeline it turned into).
    public enum Command: Equatable, Sendable {
        case play
        case pause
        case seek(to: Double)
    }

    private var lastCommand: (command: Command, seq: Int)?
    private var overridden: Command?

    /// A command given here that lost a tie: the other side changed the
    /// timeline at the same moment (often by itself: a restart after
    /// buffering, the host's player slipping) with the same sequence number
    /// and won. The command was not seen by that change, so the caller gives
    /// it again on top of it instead of letting the press of a button vanish.
    /// Returns it once.
    public mutating func takeOverriddenCommand() -> Command? {
        defer { overridden = nil }
        return overridden
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
        let made = next(playing: true, position: here, anchor: now + startLead)
        lastCommand = (.play, made.seq)
        return made
    }

    public mutating func pause(now: Double, at position: Double? = nil) -> Timeline {
        let here = position ?? timeline.expectedPosition(at: now)
        let made = next(playing: false, position: here, anchor: now)
        lastCommand = (.pause, made.seq)
        return made
    }

    public mutating func seek(to position: Double, now: Double) -> Timeline {
        let anchor = timeline.playing ? now + startLead : now
        let made = next(playing: timeline.playing, position: position, anchor: anchor)
        lastCommand = (.seek(to: made.position), made.seq)
        return made
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
        if let last = lastCommand {
            // Same number as our last command, from the other side: made at
            // the same moment from the same starting point, without knowing ours.
            if remote.seq == last.seq, remote.origin != role, timeline.seq == last.seq, timeline.origin == role { overridden = last.command }
            lastCommand = nil
        }
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
