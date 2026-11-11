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
    // Since 1.3 (all nil from older hosts, ignored by older guests):
    /// Which film of this room this is. Counts up every time the host
    /// changes or closes the film, so both sides know what belongs to what.
    public var film: Int?
    /// Label of the data channel this film's bytes arrive on (nil: "file").
    public var channel: String?
    /// Sequence number the film's timeline starts at; everything sent for
    /// an earlier film has a lower one.
    public var seq: Int?
    /// Size and a hash of sampled blocks of the bytes being sent: the same
    /// film shared again has the same fingerprint, so a guest that still has
    /// (part of) it only fetches what is missing.
    public var fingerprint: String?

    public init(size: Int64, name: String, uti: String, chunkSize: Int = ChunkFrame.defaultChunkSize,
                videoConverted: Bool? = nil, audioConverted: Bool? = nil,
                film: Int? = nil, channel: String? = nil, seq: Int? = nil, fingerprint: String? = nil) {
        self.size = size
        self.name = name
        self.uti = uti
        self.chunkSize = chunkSize
        self.videoConverted = videoConverted
        self.audioConverted = audioConverted
        self.film = film
        self.channel = channel
        self.seq = seq
        self.fingerprint = fingerprint
    }

    /// The label of the first film channel of a call (the only one before 1.3).
    public static let firstChannel = "file"
    /// Labels of the channels opened for later films.
    public static let laterChannelPrefix = "film-"
    public static func isFilmChannel(_ label: String) -> Bool { label == firstChannel || label.hasPrefix(laterChannelPrefix) }

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
    /// `t1`: the host's clock when the ping arrived. `hold` (since 1.3): how long
    /// the host kept it before answering, so that this wait is not taken for network delay.
    case pong(t0: Double, t1: Double, hold: Double? = nil)
    /// Camera on/off and mic mute state, so the other side can show it.
    case mediaState(cameraOn: Bool, micOn: Bool)
    /// Host -> guest: the film is still being converted (MKV, AVI, ...); 0...1.
    /// Older apps ignore it and simply wait for `fileInfo`.
    case preparing(fraction: Double)
    case bye
    // Since 1.3 (protocol 3). Older apps cannot decode these and ignore them.
    /// Host -> guest: the film (if any) is over; film number `film` is being
    /// looked at and will follow. Its timeline starts at `seq`.
    case filmChanging(film: Int, seq: Int)
    /// Host -> guest: no film at the moment; the room and the call go on.
    case noFilm(film: Int, seq: Int)
    /// Guest -> host: "from here on everything I send is about film `film`".
    /// Until it arrives the host ignores the guest's transfer and playback
    /// messages: they are about the film before.
    case filmAck(film: Int)
    /// Host -> guest: SHA-256 of the whole film, to check a finished copy against.
    case filmHash(film: Int, sha256: String)

    /// 1: SameSofa 1.0 to 1.2.0. 2: 1.2.1 (reconnecting in the same room,
    /// seeks that drop queued chunks). 3: 1.3 (rooms without a film, changing
    /// film without leaving, resuming a film). Versions only add optional
    /// things, so different versions still work together; they just say so.
    public static let protocolVersion = 3
    /// From this version on a partner can be in a room without a film and
    /// follow a change of film.
    public static let filmChangeVersion = 3
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
            if theirs < filmChangeVersion, ours >= filmChangeVersion {
                return .note("Your partner needs SameSofa 1.3 for rooms without a film and for changing film.")
            }
            return .note("Your partner has an older SameSofa. Some things may not work until they update.")
        }
        return .note("Your partner has a newer SameSofa. Some things may not work until you update.")
    }

    /// The note for the host of a room whose guest is too old for rooms
    /// without a film (protocol 2 and earlier): says what to do right now.
    /// nil when the partner can do everything this copy can.
    public static func oldPartnerNote(theirs: Int, hasFilm: Bool, ours: Int = protocolVersion) -> String? {
        guard theirs < filmChangeVersion, ours >= filmChangeVersion else { return nil }
        return hasFilm
            ? "Your partner needs SameSofa 1.3 for changing film. To watch something else with them now, leave and start again."
            : "Your partner needs SameSofa 1.3 for rooms without a film. Choose a film and you can watch it together."
    }

    public func encoded() -> Data {
        // Encoding these value types cannot fail.
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> ControlMessage? {
        try? JSONDecoder().decode(ControlMessage.self, from: data)
    }
}
