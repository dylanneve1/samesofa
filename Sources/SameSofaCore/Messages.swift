import Foundation

/// Who is who in a room.
public enum PeerRole: String, Codable, Sendable {
    case host
    case guest

    /// Used to break ties between commands with the same sequence number.
    var rank: Int { self == .host ? 1 : 0 }
}

/// A playback timeline both sides agree on: "the film is at `position`
/// at shared-clock time `anchor`, and is (or is not) moving at 1x".
public struct Timeline: Codable, Equatable, Sendable {
    public var playing: Bool
    public var position: Double
    /// Shared clock (host clock, seconds) at which `position` holds.
    public var anchor: Double
    public var seq: Int
    public var origin: PeerRole

    public init(playing: Bool, position: Double, anchor: Double, seq: Int, origin: PeerRole) {
        self.playing = playing
        self.position = position
        self.anchor = anchor
        self.seq = seq
        self.origin = origin
    }

    /// Where the film should be at shared time `now`. Before a scheduled
    /// start (`now < anchor`) the position stays put.
    public func expectedPosition(at now: Double) -> Double {
        guard playing else { return position }
        return position + max(0, now - anchor)
    }

    /// Ordering used to resolve two people pressing buttons at the same time.
    public func isNewer(than other: Timeline) -> Bool {
        if seq != other.seq { return seq > other.seq }
        return origin.rank > other.origin.rank
    }
}

/// Description of the film the host is sharing.
public struct FileInfo: Codable, Equatable, Sendable {
    public var size: Int64
    public var name: String
    /// Uniform type identifier, e.g. "public.mpeg-4".
    public var uti: String
    public var chunkSize: Int
    /// Did the host have to re-encode the picture / the sound to make the
    /// film playable? nil when the host's app is too old to say (before 1.2).
    public var videoConverted: Bool?
    public var audioConverted: Bool?

    public init(size: Int64, name: String, uti: String, chunkSize: Int = ChunkFrame.defaultChunkSize,
                videoConverted: Bool? = nil, audioConverted: Bool? = nil) {
        self.size = size
        self.name = name
        self.uti = uti
        self.chunkSize = chunkSize
        self.videoConverted = videoConverted
        self.audioConverted = audioConverted
    }

    public var chunkCount: Int { Int((size + Int64(chunkSize) - 1) / Int64(chunkSize)) }
}

/// Everything sent on the "control" data channel, JSON encoded.
public enum ControlMessage: Codable, Equatable, Sendable {
    case hello(role: PeerRole, protocolVersion: Int)
    /// Host -> guest: the film to expect.
    case fileInfo(FileInfo)
    /// Guest -> host: please send these chunk indices (in this order).
    /// `urgent` requests jump the host's queue (the player is waiting on them).
    /// `reset` (new apps only; older hosts ignore it): the guest has jumped, drop everything
    /// queued for the old position; the guest re-asks for whatever it still needs.
    case want(chunks: [Int], urgent: Bool, reset: Bool? = nil)
    /// Guest -> host: how much of the film has arrived (0...1).
    case progress(fraction: Double)
    /// Guest -> host: which parts of the film have arrived, as runs of
    /// chunks `[first, last]` (for the host's seek bar). Older apps ignore it.
    case have(ranges: [[Int]])
    /// Either side: a new timeline (play, pause or seek).
    case timeline(Timeline)
    /// Host -> guest every second: the current timeline plus where the host's
    /// player actually is. Lets a guest that missed something catch up.
    case heartbeat(Timeline, actualPosition: Double)
    /// Either side: "my player is starved / ready again".
    /// `position` is where this side's player stopped, so both can resume from there.
    case buffering(Bool, position: Double)
    /// Clock sync: guest sends ping with its own time, host answers with its time.
    case ping(t0: Double)
    case pong(t0: Double, t1: Double)
    /// Camera on/off and mic mute state, so the other side can show it.
    case mediaState(cameraOn: Bool, micOn: Bool)
    /// Host -> guest: the film is still being converted (MKV, AVI, ...); 0...1.
    /// Older apps ignore it and simply wait for `fileInfo`.
    case preparing(fraction: Double)
    case bye

    /// 1: SameSofa 1.0 to 1.2.0. 2: 1.2.1 (reconnecting in the same room,
    /// seeks that drop queued chunks). Versions only add optional things, so
    /// different versions still work together; they just say so.
    public static let protocolVersion = 2
    /// Partners older than this cannot be watched with at all.
    public static let oldestCompatibleVersion = 1

    /// What to tell the user about a partner announcing `theirs`.
    public enum Compatibility: Equatable, Sendable {
        case same
        /// Works, with a note (non-blocking).
        case note(String)
        /// Does not work.
        case incompatible(String)
    }

    public static func compatibility(with theirs: Int, ours: Int = protocolVersion, oldest: Int = oldestCompatibleVersion) -> Compatibility {
        if theirs == ours { return .same }
        if theirs < oldest {
            return .incompatible("Your partner's SameSofa is too old to watch together with this one. Ask them to update, then try again.")
        }
        if theirs < ours {
            return .note("Your partner has an older SameSofa. Some things may not work until they update.")
        }
        return .note("Your partner has a newer SameSofa. Some things may not work until you update.")
    }

    public func encoded() -> Data {
        // Encoding these value types cannot fail.
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> ControlMessage? {
        try? JSONDecoder().decode(ControlMessage.self, from: data)
    }
}
