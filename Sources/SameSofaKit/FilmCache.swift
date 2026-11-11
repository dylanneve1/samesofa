import Foundation
import SameSofaCore

/// Films kept on this Mac so that a film shared again does not have to be
/// sent (or converted) again:
///
///  - `received/<fingerprint>/`: a guest's copy of a film, complete or not,
///    with the map of the chunks it has;
///  - `prepared/<key>/`: a film the host converted to MP4.
///
/// Everything lives in the caches folder, is removed when it has not been
/// used for 24 hours, and the least recently used goes first when the total
/// passes the limit (20 GB unless changed in Settings). What is in use right
/// now, by this or another running copy of the app, is never removed.
public final class FilmCache {
    public static let shared = FilmCache()

    public let root: URL
    /// The most the kept films may take on disk. 0: keep nothing.
    public var capacity: Int64

    private let lock = NSLock()
    /// Entries this process is using ("received/abc…", "prepared/def…").
    private var held = Set<String>()
    private let fm = FileManager.default

    /// SAMESOFA_CACHE_DIR and SAMESOFA_CACHE_CAP_BYTES override the place and the limit (tests).
    public init(root: URL? = nil, capacity: Int64? = nil) {
        let env = ProcessInfo.processInfo.environment
        if let root {
            self.root = root
        } else if let dir = env["SAMESOFA_CACHE_DIR"], !dir.isEmpty {
            self.root = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            self.root = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.samesofa.mac", isDirectory: true)
                .appendingPathComponent("Films", isDirectory: true)
        }
        self.capacity = capacity ?? Self.configuredCapacity()
    }

    /// The limit from Settings ("keepFilmsGB": 0 switches keeping off), or the default.
    public static func configuredCapacity() -> Int64 {
        if let text = ProcessInfo.processInfo.environment["SAMESOFA_CACHE_CAP_BYTES"], let bytes = Int64(text) { return max(0, bytes) }
        if let gb = UserDefaults.standard.object(forKey: "keepFilmsGB") as? Double { return Int64(max(0, gb) * Double(1 << 30)) }
        return FilmCachePolicy.defaultCapacity
    }

    // MARK: Entries

    struct Meta: Codable {
        var size: Int64
        var chunkSize: Int
        var lastUsed: Date
        /// Received films: the chunk map, and whether the complete file matched the host's hash.
        var bitmap: Data?
        var verified: Bool?
        /// Prepared films: what the conversion did.
        var videoConverted: Bool?
        var audioConverted: Bool?
    }

    private func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private func filmURL(_ id: String) -> URL { directory(id).appendingPathComponent(id.hasPrefix("prepared/") ? "film.mp4" : "film.bin") }
    private func metaURL(_ id: String) -> URL { directory(id).appendingPathComponent("meta.json") }
    private func lockURL(_ id: String) -> URL { directory(id).appendingPathComponent("in-use") }

    private func readMeta(_ id: String) -> Meta? {
        guard let data = try? Data(contentsOf: metaURL(id)) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private func writeMeta(_ id: String, _ meta: Meta) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL(id), options: .atomic)
    }

    /// Another running copy of the app is using this entry.
    private func heldElsewhere(_ id: String) -> Bool {
        guard let text = try? String(contentsOf: lockURL(id), encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        if pid == ProcessInfo.processInfo.processIdentifier { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func hold(_ id: String) {
        held.insert(id)
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: lockURL(id), atomically: true, encoding: .utf8)
    }

    /// The entry is no longer being used by this process; it stays for a later session.
    public func release(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard held.remove(id) != nil else { return }
        try? fm.removeItem(at: lockURL(id))
        if var meta = readMeta(id) {
            meta.lastUsed = Date()
            writeMeta(id, meta)
        }
    }

    public func discard(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        held.remove(id)
        try? fm.removeItem(at: directory(id))
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    // MARK: A guest's copy of a film

    public struct Received {
        public let id: String
        public let file: URL
        /// What is already there (nil: nothing, a fresh file).
        public let map: ChunkMap?
        /// The complete file was checked against the host's hash in an earlier session.
        public let verified: Bool
    }

    /// The place for a film being received, with whatever is left of it from
    /// an earlier session. nil when it cannot be kept (no fingerprint, the
    /// limit is too small for it, or another copy of the app is receiving it
    /// right now): the caller then uses a temporary file as before.
    public func openReceived(info: FileInfo) -> Received? {
        guard let print = info.fingerprint, Self.isSafeName(print), info.size > 0, info.chunkSize > 0,
              FilmCachePolicy.canKeep(size: info.size, capacity: capacity) else { return nil }
        let id = "received/\(print)"
        lock.lock(); defer { lock.unlock() }
        guard !held.contains(id), !heldElsewhere(id) else { return nil }
        let file = filmURL(id)
        var map: ChunkMap?
        var verified = false
        if let meta = readMeta(id), meta.size == info.size, meta.chunkSize == info.chunkSize, let bitmap = meta.bitmap,
           let restored = ChunkMap(fileSize: info.size, chunkSize: info.chunkSize, bitmap: bitmap),
           let onDisk = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber, onDisk.int64Value == info.size {
            map = restored
            verified = (meta.verified ?? false) && restored.isComplete
        } else {
            // Nothing usable: start clean.
            try? fm.removeItem(at: directory(id))
        }
        let have = map.map { allocatedBytes(file) > 0 ? $0.receivedBytes : 0 } ?? 0
        sweepLocked(incoming: max(0, info.size - have), keeping: id)
        do {
            try fm.createDirectory(at: directory(id), withIntermediateDirectories: true)
            if map == nil {
                guard fm.createFile(atPath: file.path, contents: nil) else { return nil }
                writeMeta(id, Meta(size: info.size, chunkSize: info.chunkSize, lastUsed: Date(),
                                   bitmap: ChunkMap(fileSize: info.size, chunkSize: info.chunkSize).bitmap, verified: false))
            }
        } catch { return nil }
        hold(id)
        return Received(id: id, file: file, map: map, verified: verified)
    }

    /// Writes down which chunks of a received film are on disk.
    public func saveMap(_ id: String, map: ChunkMap, verified: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard held.contains(id) else { return }
        writeMeta(id, Meta(size: map.fileSize, chunkSize: map.chunkSize, lastUsed: Date(), bitmap: map.bitmap, verified: verified))
    }

    // MARK: A film the host converted

    public struct Prepared {
        public let id: String
        public let file: URL
        public let videoConverted: Bool
        public let audioConverted: Bool
    }

    /// The converted film kept under `key`, if it is still there.
    public func prepared(key: String) -> Prepared? {
        guard Self.isSafeName(key), capacity > 0 else { return nil }
        let id = "prepared/\(key)"
        lock.lock(); defer { lock.unlock() }
        guard var meta = readMeta(id), let onDisk = (try? fm.attributesOfItem(atPath: filmURL(id).path))?[.size] as? NSNumber,
              onDisk.int64Value == meta.size, meta.size > 0 else { return nil }
        meta.lastUsed = Date()
        writeMeta(id, meta)
        hold(id)
        return Prepared(id: id, file: filmURL(id), videoConverted: meta.videoConverted ?? false, audioConverted: meta.audioConverted ?? false)
    }

    /// Moves a freshly converted film into the cache. nil when it is not kept
    /// (keeping is off, or it is bigger than the limit): it then stays where
    /// it is and is deleted with the session, as before.
    public func adoptPrepared(key: String, file: URL, videoConverted: Bool, audioConverted: Bool) -> Prepared? {
        guard Self.isSafeName(key), let size = ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value,
              size > 0, FilmCachePolicy.canKeep(size: size, capacity: capacity) else { return nil }
        let id = "prepared/\(key)"
        lock.lock(); defer { lock.unlock() }
        guard !held.contains(id), !heldElsewhere(id) else { return nil }
        try? fm.removeItem(at: directory(id))
        sweepLocked(incoming: size, keeping: id)
        do {
            try fm.createDirectory(at: directory(id), withIntermediateDirectories: true)
            try fm.moveItem(at: file, to: filmURL(id))
        } catch {
            try? fm.removeItem(at: directory(id))
            return nil
        }
        writeMeta(id, Meta(size: size, chunkSize: 0, lastUsed: Date(), bitmap: nil, verified: nil,
                           videoConverted: videoConverted, audioConverted: audioConverted))
        hold(id)
        return Prepared(id: id, file: filmURL(id), videoConverted: videoConverted, audioConverted: audioConverted)
    }

    /// The cache entry a file belongs to, if it is one of ours.
    public func entryID(of file: URL) -> String? {
        let path = file.standardizedFileURL.path, base = root.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        let parts = path.dropFirst(base.count + 1).split(separator: "/")
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
    }

    // MARK: Housekeeping

    private func allocatedBytes(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    private func entriesLocked() -> [FilmCachePolicy.Entry] {
        var out: [FilmCachePolicy.Entry] = []
        for kind in ["received", "prepared"] {
            let dir = root.appendingPathComponent(kind, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
                let id = "\(kind)/\(name)"
                let modified = ((try? fm.attributesOfItem(atPath: directory(id).path))?[.modificationDate] as? Date) ?? .distantPast
                let lastUsed = readMeta(id)?.lastUsed ?? modified
                out.append(.init(id: id, bytes: allocatedBytes(filmURL(id)), lastUsed: lastUsed, inUse: held.contains(id) || heldElsewhere(id)))
            }
        }
        return out
    }

    private func sweepLocked(incoming: Int64, keeping: String? = nil, now: Date = Date()) {
        var entries = entriesLocked()
        if let keeping, let index = entries.firstIndex(where: { $0.id == keeping }) { entries[index].inUse = true }
        for id in FilmCachePolicy.evictions(entries: entries, now: now, capacity: capacity, incoming: incoming) {
            Log.debug("film cache: removing \(id.prefix(20))…")
            try? fm.removeItem(at: directory(id))
        }
    }

    /// Removes what is too old and, if the total is over the limit, the least recently used.
    public func sweep(incoming: Int64 = 0, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        sweepLocked(incoming: incoming, now: now)
    }

    /// Removes everything that is not in use right now. Returns the bytes freed.
    @discardableResult
    public func clear() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var freed: Int64 = 0
        for entry in entriesLocked() where !entry.inUse {
            freed += entry.bytes
            try? fm.removeItem(at: directory(entry.id))
        }
        return freed
    }

    /// Space the kept films take on disk.
    public var totalBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return entriesLocked().reduce(0) { $0 + $1.bytes }
    }

    /// For tests and the settings window: what is kept.
    public var entries: [FilmCachePolicy.Entry] {
        lock.lock(); defer { lock.unlock() }
        return entriesLocked()
    }

    /// Test hook: pretend an entry was last used at `date`.
    public func setLastUsedForTesting(_ id: String, _ date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard var meta = readMeta(id) else { return }
        meta.lastUsed = date
        writeMeta(id, meta)
    }
}
