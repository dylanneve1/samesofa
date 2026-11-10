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

    public init(size: Int64, name: String, uti: String, chunkSize: Int = ChunkFrame.defaultChunkSize) {
        self.size = size
        self.name = name
        self.uti = uti
        self.chunkSize = chunkSize
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
    case want(chunks: [Int], urgent: Bool)
    /// Guest -> host: how much of the film has arrived (0...1).
    case progress(fraction: Double)
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

    public static let protocolVersion = 1

    public func encoded() -> Data {
        // Encoding these value types cannot fail.
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> ControlMessage? {
        try? JSONDecoder().decode(ControlMessage.self, from: data)
    }
}
