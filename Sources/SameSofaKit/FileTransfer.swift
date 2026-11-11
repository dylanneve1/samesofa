import AVFoundation
import Foundation
import SameSofaCore
import UniformTypeIdentifiers
import WebRTC

/// Host side: answers the guest's chunk requests by reading the original film
/// file and sending it over the "file" data channel, never queueing more than
/// a couple of megabytes inside WebRTC (backpressure via bufferedAmount).
final class FileSender: NSObject, RTCDataChannelDelegate {
    let info: FileInfo
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "samesofa.file.sender")
    private var channel: RTCDataChannel?
    private var pending: [Int] = []
    private var pendingSet = Set<Int>()
    /// Small on purpose: SCTP sends in arrival order, so whatever film is queued
    /// here is the added latency of a play/pause/seek on the control channel
    /// (256 KiB is about 50 ms at 40 Mbit/s).
    private let highWater: UInt64 = 256 * 1024
    private(set) var bytesSent: Int64 = 0
    /// Optional upload cap for testing slow connections (SAMESOFA_THROTTLE_BPS).
    private let throttleBytesPerSecond: Double?
    private var tokens: Double = 0
    private var lastRefill = Date()
    private var throttleWakeScheduled = false

    let url: URL

    /// `name` is what the guest is told the film is called (defaults to the file name).
    /// `videoConverted`/`audioConverted`: whether the film had to be re-encoded, for the guest's readout.
    /// `rateLimit`: bytes per second this sender may use at most (a film sent ahead leaves room for the call).
    init(url: URL, name: String? = nil, videoConverted: Bool? = nil, audioConverted: Bool? = nil, rateLimit: Double? = nil) throws {
        let testLimit = ProcessInfo.processInfo.environment["SAMESOFA_THROTTLE_BPS"].flatMap(Double.init)
        throttleBytesPerSecond = [rateLimit, testLimit].compactMap { $0 }.min()
        self.url = url
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.mpeg4Movie.identifier
        handle = try FileHandle(forReadingFrom: url)
        // Lets a guest that still has this film (or part of it) recognise it.
        let fingerprint = try? FilmFingerprint.compute(file: url)
        info = FileInfo(size: size, name: name ?? url.lastPathComponent, uti: uti,
                        videoConverted: videoConverted, audioConverted: audioConverted, fingerprint: fingerprint)
    }

    private let stopLock = NSLock()
    private var stopped = false
    private var isStopped: Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopped }

    /// This film is over (another one, or none): nothing more is sent.
    func stop() {
        stopLock.lock(); stopped = true; stopLock.unlock()
        detach()
    }

    private static var knownHashes: [String: String] = [:]
    private static let knownHashesLock = NSLock()

    /// SHA-256 of the whole file, worked out in the background (once per
    /// file while the app runs); `done` is called on the main queue unless
    /// the film was stopped first.
    func computeFullHash(_ done: @escaping (String) -> Void) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.path)|\(info.size)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        Self.knownHashesLock.lock(); let known = Self.knownHashes[key]; Self.knownHashesLock.unlock()
        if let known { DispatchQueue.main.async { if !self.isStopped { done(known) } }; return }
        DispatchQueue.global(qos: .utility).async {
            guard let hash = FilmFingerprint.fullHash(file: self.url, cancelled: { self.isStopped }) else { return }
            Self.knownHashesLock.lock(); Self.knownHashes[key] = hash; Self.knownHashesLock.unlock()
            DispatchQueue.main.async { if !self.isStopped { done(hash) } }
        }
    }

    func attach(_ channel: RTCDataChannel) {
        queue.async {
            self.channel = channel
            ChannelRelay.attach(channel, to: self)
            self.pump()
        }
    }

    func detach() {
        queue.async {
            if let channel = self.channel { ChannelRelay.attach(channel, to: nil) }
            self.channel = nil
            self.pending.removeAll()
            self.pendingSet.removeAll()
        }
    }

    func request(_ chunks: [Int], urgent: Bool, reset: Bool = false) {
        Log.debug("sender: want \(chunks.count) urgent=\(urgent) first=\(chunks.first ?? -1)")
        queue.async {
            let fresh = chunks.filter { $0 >= 0 && $0 < self.info.chunkCount }
            if urgent {
                if reset { self.pending.removeAll(); self.pendingSet.removeAll() }
                self.pending.removeAll { fresh.contains($0) }
                self.pending.insert(contentsOf: fresh, at: 0)
                self.pendingSet.formUnion(fresh)
            } else {
                for c in fresh where !self.pendingSet.contains(c) {
                    self.pending.append(c)
                    self.pendingSet.insert(c)
                }
            }
            self.pump()
        }
    }

    /// Chunks handed to the data channel since the film started (diagnostics, tests).
    private(set) var chunksSent = 0

    private func pump() {
        guard let channel, channel.readyState == .open else { return }
        while !pending.isEmpty, channel.bufferedAmount < highWater {
            if let rate = throttleBytesPerSecond {
                let now = Date()
                tokens = min(rate, tokens + now.timeIntervalSince(lastRefill) * rate)
                lastRefill = now
                if tokens < Double(info.chunkSize) {
                    if !throttleWakeScheduled {
                        throttleWakeScheduled = true
                        queue.asyncAfter(deadline: .now() + 0.05) { self.throttleWakeScheduled = false; self.pump() }
                    }
                    return
                }
                tokens -= Double(info.chunkSize)
            }
            let index = pending.removeFirst()
            pendingSet.remove(index)
            let offset = Int64(index) * Int64(info.chunkSize)
            let length = Int(min(Int64(info.chunkSize), info.size - offset))
            guard length > 0 else { continue }
            let payload: Data
            do {
                try handle.seek(toOffset: UInt64(offset))
                payload = try handle.read(upToCount: length) ?? Data()
            } catch { continue }
            let frame = ChunkFrame.encode(offset: offset, payload: payload)
            if channel.sendData(RTCDataBuffer(data: frame, isBinary: true)) {
                bytesSent += Int64(payload.count)
                chunksSent += 1
            } else {
                pending.insert(index, at: 0)
                pendingSet.insert(index)
                break
            }
        }
    }

    // RTCDataChannelDelegate
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) { queue.async { self.pump() } }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}
    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        queue.async { self.pump() }
    }
}

/// Guest side: receives the film into a sparse local file and feeds AVPlayer
/// through a custom URL scheme (AVAssetResourceLoaderDelegate), so playback
/// can start long before the whole file has arrived. Byte ranges the player
/// asks for are fetched first, which also handles MP4 files that keep their
/// index ("moov" atom) at the very end.
///
/// A film the host describes with a fingerprint is received into the film
/// cache: if (part of) it is there from an earlier session, only what is
/// missing is fetched, and the copy stays for the next time. Otherwise the
/// film goes to a temporary file that is deleted with this object.
public final class FileReceiver: NSObject, RTCDataChannelDelegate, AVAssetResourceLoaderDelegate {
    public static let scheme = "samesofa-film"
    public let info: FileInfo
    public let cacheURL: URL
    let queue = DispatchQueue(label: "samesofa.file.receiver")
    private let writer: FileHandle
    private let reader: FileHandle
    private var scheduler: ChunkScheduler
    private var channel: RTCDataChannel?
    private var loadingRequests: [AVAssetResourceLoadingRequest] = []
    /// Sends `want` messages on the control channel.
    var requestChunks: (([Int], Bool, Bool) -> Void)?
    /// Fraction received, called on the main queue (throttled).
    var onProgress: ((Double) -> Void)?
    /// Which parts have arrived (runs of chunks, chunk count), with every progress report.
    var onRanges: (([[Int]], Int) -> Void)?
    private var lastProgressReport = Date.distantPast
    public private(set) var bytesReceived: Int64 = 0

    // Resuming
    private let cache: FilmCache?
    private let cacheID: String?
    /// Chunks that were already on this Mac when this session started.
    public let resumedChunks: Int
    /// The chunks taken over from an earlier session (to fetch again if the finished film does not check out).
    private var resumed: ChunkMap?
    private var lastMapSave = Date.distantPast
    private var cancelled = false
    private var expectedHash: String?
    private var verifying = false
    private var verified: Bool?
    private var refetches = 0
    private var chunksFetched = 0

    /// Where the transfer stands (for the readout and tests).
    public struct Status: Equatable, Sendable {
        /// Chunks the film has, chunks here now, chunks that were here from an earlier session,
        /// chunks that arrived over the network in this session.
        public var chunkCount = 0, received = 0, resumed = 0, fetched = 0
        /// nil: not checked (yet). true: the complete file matches the host's hash.
        public var verified: Bool?
        /// How often a finished copy did not match and the resumed part was fetched again.
        public var refetches = 0
        public var isKept = false
        public init() {}
    }

    public var status: Status {
        queue.sync {
            var status = Status()
            status.chunkCount = scheduler.map.chunkCount
            status.received = scheduler.map.receivedCount
            status.resumed = resumedChunks
            status.fetched = chunksFetched
            status.verified = verified
            status.refetches = refetches
            status.isKept = cacheID != nil
            return status
        }
    }

    public init(info: FileInfo, cache: FilmCache? = FilmCache.shared) throws {
        self.info = info
        // One folder per running copy of the app: a second copy on the same
        // Mac (or a test running next to it) keeps its own film.
        ReceivedFilms.removeLeftovers()
        var map = ChunkMap(fileSize: info.size, chunkSize: info.chunkSize)
        var kept: FilmCache.Received?
        if let cache, let entry = cache.openReceived(info: info) {
            kept = entry
            if let have = entry.map { map = have }
        }
        if let kept {
            cacheURL = kept.file
            self.cache = cache
            cacheID = kept.id
        } else {
            let dir = ReceivedFilms.directory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = (info.name as NSString).pathExtension
            cacheURL = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.isEmpty ? "mp4" : ext)
            FileManager.default.createFile(atPath: cacheURL.path, contents: nil)
            self.cache = nil
            cacheID = nil
        }
        do {
            writer = try FileHandle(forWritingTo: cacheURL)
            if kept?.map == nil { try writer.truncate(atOffset: UInt64(info.size)) } // sparse on APFS
            reader = try FileHandle(forReadingFrom: cacheURL)
        } catch {
            if let id = kept?.id { cache?.discard(id) } else { try? FileManager.default.removeItem(at: cacheURL) }
            throw error
        }
        resumedChunks = map.receivedCount
        resumed = map.receivedCount > 0 ? map : nil
        if kept?.verified == true { verified = true }
        scheduler = ChunkScheduler(map: map)
        super.init()
        if resumedChunks > 0 { Log.debug("receiver: resuming with \(resumedChunks) of \(map.chunkCount) chunks already here") }
    }

    deinit {
        try? writer.close()
        try? reader.close()
        if let cache, let cacheID {
            if !released {
                cache.saveMap(cacheID, map: scheduler.map, verified: verified == true)
                cache.release(cacheID)
            }
        } else {
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    /// The kept copy has been handed back to the cache (by `cancel`): another receiver may take it over.
    private var released = false

    /// Is this film kept for a later session?
    public var isKept: Bool { cacheID != nil }

    /// This film is over (another one, or none): stop listening, let go of
    /// the player's requests, write down what has arrived.
    func cancel() {
        queue.sync {
            cancelled = true
            if let channel { ChannelRelay.attach(channel, to: nil) }
            channel = nil
            for request in loadingRequests where !request.isFinished && !request.isCancelled {
                request.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            }
            loadingRequests.removeAll()
            requestChunks = nil
            onProgress = nil
            onRanges = nil
            // Written down and handed back at once (not when this object happens to go away): the same
            // film may be announced again in the next moment, and must find its copy free.
            if let cache, let cacheID, !released {
                cache.saveMap(cacheID, map: scheduler.map, verified: verified == true)
                cache.release(cacheID)
                released = true
            }
        }
    }

    /// The channel this receiver listens on (nil: none yet).
    var attachedChannel: RTCDataChannel? { queue.sync { channel } }

    private func saveMap(force: Bool = false) {
        guard let cache, let cacheID, !released, force || Date().timeIntervalSince(lastMapSave) > 2 else { return }
        lastMapSave = Date()
        cache.saveMap(cacheID, map: scheduler.map, verified: verified == true)
    }

    /// Tells the listeners where the transfer stands right now (what was
    /// resumed shows at once, before the first chunk arrives).
    func reportNow() {
        queue.async { self.report() }
    }

    private func report() {
        lastProgressReport = Date()
        let fraction = scheduler.map.fraction
        if let onProgress { DispatchQueue.main.async { onProgress(fraction) } }
        if let onRanges {
            let ranges = scheduler.map.ranges(), count = scheduler.map.chunkCount
            DispatchQueue.main.async { onRanges(ranges, count) }
        }
    }

    // MARK: Checking a finished copy

    /// The host's SHA-256 of the whole film. A complete copy is compared
    /// with it; if a resumed copy does not match, the resumed part is
    /// fetched again.
    func setExpectedHash(_ hash: String) {
        queue.async {
            self.expectedHash = hash
            self.verifyIfComplete()
        }
    }

    private func verifyIfComplete() {
        guard scheduler.map.isComplete, let expected = expectedHash, !verifying, !cancelled else { return }
        // Checked in an earlier session and nothing new since: check again all the same, it is cheap next to a film.
        verifying = true
        let url = cacheURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let actual = FilmFingerprint.fullHash(file: url, cancelled: { self == nil })
            guard let self else { return }
            self.queue.async {
                self.verifying = false
                guard !self.cancelled, let actual else { return }
                if actual == expected {
                    self.verified = true
                    Log.debug("receiver: complete copy matches the host's hash")
                    self.saveMap(force: true)
                } else if let resumed = self.resumed {
                    // Something kept from an earlier session is damaged: fetch that part again.
                    Log.debug("receiver: complete copy does not match; fetching the resumed \(resumed.receivedCount) chunks again")
                    self.verified = nil
                    self.refetches += 1
                    self.scheduler.forget((0..<resumed.chunkCount).filter { resumed.has($0) })
                    self.resumed = nil
                    self.saveMap(force: true)
                    self.report()
                    self.requestMore()
                } else {
                    self.verified = false
                    Log.debug("receiver: complete copy does not match the host's hash")
                    self.saveMap(force: true)
                }
            }
        }
    }

    /// The URL to give AVURLAsset; its resource loader must use this object.
    public var playerURL: URL {
        let ext = (info.name as NSString).pathExtension
        return URL(string: "\(Self.scheme)://film/movie.\(ext.isEmpty ? "mp4" : ext)")!
    }

    public var isComplete: Bool { queue.sync { scheduler.map.isComplete } }
    public var fraction: Double { queue.sync { scheduler.map.fraction } }

    /// Bytes available without a gap from `offset`.
    func contiguousBytes(from offset: Int64) -> Int64 { queue.sync { scheduler.map.contiguousBytes(from: offset) } }

    func attach(_ channel: RTCDataChannel) {
        queue.async {
            guard !self.cancelled else { return }
            if let old = self.channel, old !== channel { ChannelRelay.attach(old, to: nil) }
            self.channel = channel
            ChannelRelay.attach(channel, to: self)
            self.scheduler.resetInFlight()
            self.requestMore()
        }
    }

    /// Hint from playback: the film is around this byte offset.
    func setPlayhead(offset: Int64) {
        queue.async {
            self.scheduler.setPlayhead(offset: offset)
            self.requestMore()
        }
    }

    private func requestMore() {
        guard !cancelled else { return }
        let urgent = scheduler.hasUrgent
        // The player jumped: what was queued at the host for the old position is stale.
        let jump = urgent && scheduler.urgentIsJump
        if jump { scheduler.resetInFlight() }
        Log.debug("receiver: requestMore inflight=\(scheduler.inFlight.count) received=\(scheduler.map.receivedCount)")
        let next = scheduler.nextRequests()
        guard !next.isEmpty, let requestChunks else { return }
        DispatchQueue.main.async { requestChunks(next, urgent, jump) }
    }

    // MARK: Incoming chunks

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.isBinary, let (offset, payload) = ChunkFrame.decode(buffer.data) else { return }
        queue.async { self.store(offset: offset, payload: payload) }
    }

    func store(offset: Int64, payload: Data) {
        guard !cancelled, offset >= 0, offset < info.size else { return }
        let index = scheduler.map.chunkIndex(forOffset: offset)
        guard offset % Int64(info.chunkSize) == 0, payload.count == scheduler.map.length(ofChunk: index) else { return }
        if !scheduler.map.has(index) {
            do {
                try writer.seek(toOffset: UInt64(offset))
                try writer.write(contentsOf: payload)
            } catch { return }
            bytesReceived += Int64(payload.count)
            chunksFetched += 1
        }
        scheduler.received(index)
        serviceLoadingRequests()
        requestMore()
        let complete = scheduler.map.isComplete
        if complete || Date().timeIntervalSince(lastProgressReport) > 0.5 { report() }
        saveMap(force: complete)
        if complete { verifyIfComplete() }
    }

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    // MARK: AVAssetResourceLoaderDelegate (runs on `queue`)

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !cancelled else { return false }
        if let content = loadingRequest.contentInformationRequest {
            content.contentType = info.uti
            content.contentLength = info.size
            content.isByteRangeAccessSupported = true
        }
        if let data = loadingRequest.dataRequest {
            let offset = data.currentOffset
            let length = data.requestsAllDataToEndOfResource ? info.size - offset : Int64(data.requestedLength)
            scheduler.prioritize(offset: offset, length: length)
            if !data.requestsAllDataToEndOfResource || data.requestedLength > 2 { scheduler.setPlayhead(offset: offset) }
            loadingRequests.append(loadingRequest)
            serviceLoadingRequests()
            requestMore()
        } else {
            loadingRequest.finishLoading()
        }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        loadingRequests.removeAll { $0 === loadingRequest }
    }

    private var serviceScheduled = false

    /// Hands available bytes to waiting player requests, at most a few MB per
    /// request per pass so a "give me the rest of the file" request cannot
    /// pull gigabytes into memory at once.
    private func serviceLoadingRequests() {
        var moreReady = false
        loadingRequests.removeAll { request in
            guard !request.isCancelled, !request.isFinished else { return true }
            guard let data = request.dataRequest else { request.finishLoading(); return true }
            let end = data.requestsAllDataToEndOfResource ? info.size : min(info.size, data.requestedOffset + Int64(data.requestedLength))
            var offset = data.currentOffset
            var budget: Int64 = 4 << 20
            while offset < end, budget > 0 {
                let available = min(scheduler.map.contiguousBytes(from: offset), end - offset)
                if available <= 0 { break }
                let piece = Int(min(available, 1 << 20))
                do {
                    try reader.seek(toOffset: UInt64(offset))
                    guard let bytes = try reader.read(upToCount: piece), !bytes.isEmpty else { break }
                    data.respond(with: bytes)
                    offset += Int64(bytes.count)
                    budget -= Int64(bytes.count)
                } catch { break }
            }
            if offset >= end {
                request.finishLoading()
                return true
            }
            if budget <= 0 { moreReady = true }
            return false
        }
        if moreReady, !serviceScheduled {
            serviceScheduled = true
            queue.asyncAfter(deadline: .now() + 0.02) {
                self.serviceScheduled = false
                self.serviceLoadingRequests()
            }
        }
    }
}

/// Where a guest keeps the film it is receiving: `<temporary folder>/SameSofa/<process id>/`.
/// Whatever a copy of the app that is no longer running left behind is
/// removed the next time a film is received; a copy that is still running
/// keeps its files.
public enum ReceivedFilms {
    public static var parent: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SameSofa", isDirectory: true)
    }

    public static var directory: URL {
        parent.appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
    }

    public static func removeLeftovers() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] {
            let url = parent.appendingPathComponent(name)
            if let pid = Int32(name), pid > 0 {
                // Our own folder and those of copies that are still running stay.
                if pid == ProcessInfo.processInfo.processIdentifier || kill(pid, 0) == 0 || errno == EPERM { continue }
                try? fm.removeItem(at: url)
            } else if let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      Date().timeIntervalSince(modified) > 24 * 3600 {
                // A film left loose in the folder by 1.2.0 or earlier, not touched for a day.
                try? fm.removeItem(at: url)
            }
        }
    }
}
