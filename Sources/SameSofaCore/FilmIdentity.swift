import CryptoKit
import Foundation

/// Recognises a film that is shared again, without reading all of it: its
/// size and a SHA-256 over blocks sampled along the file. Two files with the
/// same fingerprint are the same film for the purpose of resuming; a finished
/// copy is still checked against the hash of the whole file.
public enum FilmFingerprint {
    public static let blockSize = 64 * 1024
    public static let blockCount = 24

    /// Where the sampled blocks start: the first, the last, and the rest evenly in between.
    public static func sampleOffsets(size: Int64) -> [Int64] {
        guard size > 0 else { return [] }
        let block = Int64(blockSize)
        if size <= block * Int64(blockCount) {
            // Small enough to read whole.
            return stride(from: Int64(0), to: size, by: Int(block)).map { $0 }
        }
        let last = size - block
        return (0..<blockCount).map { i in last * Int64(i) / Int64(blockCount - 1) }
    }

    /// `read(offset, length)` returns up to `length` bytes of the film at `offset`.
    public static func compute(size: Int64, read: (Int64, Int) throws -> Data) rethrows -> String {
        var hasher = SHA256()
        hasher.update(data: Data("samesofa-film-1:\(size):".utf8))
        for offset in sampleOffsets(size: size) {
            let length = Int(min(Int64(blockSize), size - offset))
            hasher.update(data: try read(offset, length))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func compute(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        return try compute(size: size) { offset, length in
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length) ?? Data()
        }
    }

    /// SHA-256 of a whole file, as hex. `cancelled` is polled between blocks.
    public static func fullHash(file: URL, cancelled: () -> Bool = { false }) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if cancelled() { return nil }
            let data: Data?
            do { data = try handle.read(upToCount: 4 << 20) } catch { return nil }
            // nil or empty: the end of the file.
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The key under which the host keeps a converted film: what went in
    /// (the source's fingerprint, and that of a subtitle file next to it)
    /// and how it was converted. Conversion with a hardware encoder does not
    /// give the same bytes twice, so the converted file itself is kept and
    /// found again by this key.
    public static func conversionKey(source: String, sidecar: String?, arguments: [String], tool: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("samesofa-prepared-1\n\(source)\n\(sidecar ?? "-")\n\(tool)\n".utf8))
        for argument in arguments { hasher.update(data: Data((argument + "\u{0}").utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Which kept films go when room is needed. Pure bookkeeping; the files are
/// handled by `FilmCache` in SameSofaKit.
public enum FilmCachePolicy {
    public static let defaultCapacity: Int64 = 20 << 30
    public static let maxAge: TimeInterval = 24 * 3600

    public struct Entry: Equatable, Sendable {
        public var id: String
        /// Space it takes on disk.
        public var bytes: Int64
        public var lastUsed: Date
        /// Being received, sent or played right now: never removed.
        public var inUse: Bool

        public init(id: String, bytes: Int64, lastUsed: Date, inUse: Bool = false) {
            self.id = id
            self.bytes = bytes
            self.lastUsed = lastUsed
            self.inUse = inUse
        }
    }

    /// The entries to delete: everything not used for `maxAge`, then the
    /// least recently used until what is left plus `incoming` bytes fits in
    /// `capacity`. Entries in use stay, whatever their age or size.
    public static func evictions(entries: [Entry], now: Date, capacity: Int64, incoming: Int64 = 0,
                                 maxAge: TimeInterval = FilmCachePolicy.maxAge) -> [String] {
        var out: [String] = []
        var kept: [Entry] = []
        for entry in entries {
            if !entry.inUse, now.timeIntervalSince(entry.lastUsed) > maxAge { out.append(entry.id) } else { kept.append(entry) }
        }
        var total = kept.reduce(Int64(0)) { $0 + $1.bytes } + max(0, incoming)
        for entry in kept.sorted(by: { $0.lastUsed < $1.lastUsed }) where total > capacity && !entry.inUse {
            out.append(entry.id)
            total -= entry.bytes
        }
        return out
    }

    /// Can a film of this size be kept at all?
    public static func canKeep(size: Int64, capacity: Int64) -> Bool { capacity > 0 && size <= capacity }
}

/// Host: which film the room is on, and whether what the guest sends is
/// about that film. Every change (another film, no film) gets the next
/// number; the guest confirms each one, and until it has, its transfer and
/// playback messages are about the film before and are ignored.
public struct FilmTurn: Equatable, Sendable {
    /// 0: no film has been set in this room yet.
    public private(set) var current = 0
    /// The last film number the guest confirmed (nil: none yet on this connection).
    public private(set) var confirmed: Int?
    /// The partner's protocol version (nil: not said yet).
    public var partnerVersion: Int?

    public init() {}

    /// The film changes: returns its number.
    @discardableResult
    public mutating func advance() -> Int {
        current += 1
        return current
    }

    public mutating func confirm(_ film: Int) { confirmed = film }

    /// A new connection (or a new partner): nothing is confirmed yet.
    public mutating func connectionReset() {
        confirmed = nil
        partnerVersion = nil
    }

    /// The partner follows changes of film (1.3 and later).
    public var partnerFollowsChanges: Bool { (partnerVersion ?? 0) >= ControlMessage.filmChangeVersion }

    /// Do the guest's messages about "the film" apply to the current one?
    /// An older guest has only ever been told about one film, so yes.
    public var guestIsOnCurrentFilm: Bool {
        guard partnerVersion != nil else { return false }
        if !partnerFollowsChanges { return true }
        return confirmed == current
    }
}
