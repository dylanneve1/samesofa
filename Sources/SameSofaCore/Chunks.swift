import Foundation

/// Binary frames on the "file" data channel: an 8-byte big-endian byte offset
/// followed by the chunk payload.
public enum ChunkFrame {
    /// 64 KiB keeps each SCTP message comfortably under WebRTC's 256 KiB limit.
    public static let defaultChunkSize = 64 * 1024
    public static let headerSize = 8

    public static func encode(offset: Int64, payload: Data) -> Data {
        var data = Data(capacity: headerSize + payload.count)
        var be = UInt64(offset).bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    public static func decode(_ frame: Data) -> (offset: Int64, payload: Data)? {
        guard frame.count >= headerSize else { return nil }
        var value: UInt64 = 0
        for byte in frame.prefix(headerSize) { value = (value << 8) | UInt64(byte) }
        return (Int64(value), frame.dropFirst(headerSize))
    }
}

/// Which chunks of the film have arrived.
public struct ChunkMap: Sendable {
    public let fileSize: Int64
    public let chunkSize: Int
    public private(set) var receivedCount = 0
    private var bits: [UInt64]

    public init(fileSize: Int64, chunkSize: Int) {
        self.fileSize = fileSize
        self.chunkSize = chunkSize
        let chunks = Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize))
        bits = Array(repeating: 0, count: (chunks + 63) / 64)
        self.chunkCount = chunks
    }

    public let chunkCount: Int
    public var isComplete: Bool { receivedCount == chunkCount }
    public var fraction: Double { chunkCount == 0 ? 1 : Double(receivedCount) / Double(chunkCount) }

    public func has(_ index: Int) -> Bool {
        guard index >= 0, index < chunkCount else { return false }
        return bits[index >> 6] & (1 << UInt64(index & 63)) != 0
    }

    @discardableResult
    public mutating func mark(_ index: Int) -> Bool {
        guard index >= 0, index < chunkCount, !has(index) else { return false }
        bits[index >> 6] |= (1 << UInt64(index & 63))
        receivedCount += 1
        return true
    }

    public func chunkIndex(forOffset offset: Int64) -> Int { Int(offset / Int64(chunkSize)) }

    /// Expected payload length of a chunk (the last one may be short).
    public func length(ofChunk index: Int) -> Int {
        let start = Int64(index) * Int64(chunkSize)
        return Int(min(Int64(chunkSize), fileSize - start))
    }

    /// Chunks overlapping [offset, offset+length) that have not arrived.
    public func missing(offset: Int64, length: Int64) -> [Int] {
        guard length > 0, offset < fileSize else { return [] }
        let first = chunkIndex(forOffset: max(0, offset))
        let last = chunkIndex(forOffset: min(fileSize, offset + length) - 1)
        return (first...last).filter { !has($0) }
    }

    /// How many bytes starting at `offset` are available without a gap.
    public func contiguousBytes(from offset: Int64) -> Int64 {
        guard offset < fileSize else { return 0 }
        var index = chunkIndex(forOffset: offset)
        var end = offset
        while index < chunkCount, has(index) {
            end = min(fileSize, Int64(index + 1) * Int64(chunkSize))
            index += 1
        }
        return end - offset
    }
}

/// Decides which chunks the guest asks the host for next.
///
/// Order of preference:
///  1. ranges the player is waiting on right now (newest request first),
///  2. the end of the file (MP4 files often keep their index there),
///  3. everything from the current playback point forwards,
///  4. everything before it.
/// A fixed window of requests is kept in flight so the host is never idle but
/// a seek can redirect the transfer within a fraction of a second.
public struct ChunkScheduler: Sendable {
    public var map: ChunkMap
    public var window: Int
    public private(set) var inFlight = Set<Int>()
    private var urgent: [Int] = []
    public var playheadChunk = 0
    public var tailChunks = 16

    public init(map: ChunkMap, window: Int = 24) {
        self.map = map
        self.window = window
    }

    /// The player needs these bytes now.
    public mutating func prioritize(offset: Int64, length: Int64) {
        let wanted = map.missing(offset: offset, length: min(length, 64 * Int64(map.chunkSize)))
        urgent.removeAll { wanted.contains($0) }
        urgent.insert(contentsOf: wanted, at: 0)
    }

    public mutating func setPlayhead(offset: Int64) {
        playheadChunk = map.chunkIndex(forOffset: max(0, min(offset, map.fileSize - 1)))
    }

    /// Records an arrival. Returns false for duplicates or unknown chunks.
    @discardableResult
    public mutating func received(_ index: Int) -> Bool {
        inFlight.remove(index)
        return map.mark(index)
    }

    /// True while the player is waiting on chunks that have not been requested yet.
    public var hasUrgent: Bool { urgent.contains { !map.has($0) && !inFlight.contains($0) } }

    /// True when the chunks the player is waiting on are far from anything already requested: a jump.
    public var urgentIsJump: Bool {
        guard let first = urgent.first(where: { !map.has($0) && !inFlight.contains($0) }) else { return false }
        return !inFlight.contains { abs($0 - first) <= window }
    }

    /// Next chunk indices to request, filling the window.
    public mutating func nextRequests() -> [Int] {
        var out: [Int] = []
        let budget = window - inFlight.count
        guard budget > 0, !map.isComplete else { return [] }

        var picked = Set<Int>()
        func take(_ index: Int) {
            guard out.count < budget, index >= 0, index < map.chunkCount,
                  !map.has(index), !inFlight.contains(index), !picked.contains(index) else { return }
            out.append(index)
            picked.insert(index)
        }

        urgent.removeAll { map.has($0) }
        for index in urgent { take(index) }
        let tailStart = max(0, map.chunkCount - tailChunks)
        for index in tailStart..<map.chunkCount where out.count < budget { take(index) }
        var index = playheadChunk
        while index < map.chunkCount, out.count < budget { take(index); index += 1 }
        index = 0
        while index < playheadChunk, out.count < budget { take(index); index += 1 }
        inFlight.formUnion(out)
        urgent.removeAll { inFlight.contains($0) }
        return out
    }

    /// Forget in-flight requests (e.g. after a reconnect) so they get re-asked.
    public mutating func resetInFlight() { inFlight.removeAll() }
}

extension ChunkMap {
    /// The received parts as runs of chunks `[first, last]`, in order. With
    /// more than `limit` runs (a film scrubbed through many times) the
    /// narrowest gaps are closed until `limit` are left: it is a picture for
    /// the seek bar, not a record.
    public func ranges(limit: Int = 48) -> [[Int]] {
        var runs: [[Int]] = []
        var start: Int?
        for index in 0..<chunkCount {
            if has(index) {
                if start == nil { start = index }
            } else if let first = start {
                runs.append([first, index - 1])
                start = nil
            }
        }
        if let first = start { runs.append([first, chunkCount - 1]) }
        while runs.count > max(1, limit) {
            var narrowest = 1
            for i in 1..<runs.count where runs[i][0] - runs[i - 1][1] < runs[narrowest][0] - runs[narrowest - 1][1] { narrowest = i }
            runs[narrowest - 1][1] = runs[narrowest][1]
            runs.remove(at: narrowest)
        }
        return runs
    }

    /// Runs of chunks as shares of the film (0...1). Anything malformed is left out.
    public static func fractions(ranges: [[Int]], chunkCount: Int) -> [ClosedRange<Double>] {
        guard chunkCount > 0 else { return [] }
        return ranges.compactMap { run in
            guard run.count == 2, run[0] >= 0, run[1] >= run[0], run[1] < chunkCount else { return nil }
            return (Double(run[0]) / Double(chunkCount))...(Double(run[1] + 1) / Double(chunkCount))
        }
    }

    public static func chunkCount(fileSize: Int64, chunkSize: Int) -> Int {
        chunkSize > 0 ? Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)) : 0
    }
}
