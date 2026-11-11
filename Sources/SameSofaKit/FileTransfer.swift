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
    init(url: URL, name: String? = nil, videoConverted: Bool? = nil, audioConverted: Bool? = nil) throws {
        throttleBytesPerSecond = ProcessInfo.processInfo.environment["SAMESOFA_THROTTLE_BPS"].flatMap(Double.init)
        self.url = url
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.mpeg4Movie.identifier
        info = FileInfo(size: size, name: name ?? url.lastPathComponent, uti: uti,
                        videoConverted: videoConverted, audioConverted: audioConverted)
        handle = try FileHandle(forReadingFrom: url)
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
    private var lastProgressReport = Date.distantPast
    public private(set) var bytesReceived: Int64 = 0

    public init(info: FileInfo) throws {
        self.info = info
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SameSofa", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Old partial films from earlier sessions are not needed any more.
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in old { try? FileManager.default.removeItem(at: url) }
        }
        let ext = (info.name as NSString).pathExtension
        cacheURL = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.isEmpty ? "mp4" : ext)
        FileManager.default.createFile(atPath: cacheURL.path, contents: nil)
        writer = try FileHandle(forWritingTo: cacheURL)
        try writer.truncate(atOffset: UInt64(info.size)) // sparse on APFS
        reader = try FileHandle(forReadingFrom: cacheURL)
        scheduler = ChunkScheduler(map: ChunkMap(fileSize: info.size, chunkSize: info.chunkSize))
        super.init()
    }

    deinit {
        try? writer.close()
        try? reader.close()
        try? FileManager.default.removeItem(at: cacheURL)
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
        let index = scheduler.map.chunkIndex(forOffset: offset)
        guard offset % Int64(info.chunkSize) == 0, payload.count == scheduler.map.length(ofChunk: index) else { return }
        if !scheduler.map.has(index) {
            do {
                try writer.seek(toOffset: UInt64(offset))
                try writer.write(contentsOf: payload)
            } catch { return }
            bytesReceived += Int64(payload.count)
        }
        scheduler.received(index)
        serviceLoadingRequests()
        requestMore()
        if scheduler.map.isComplete || Date().timeIntervalSince(lastProgressReport) > 0.5 {
            lastProgressReport = Date()
            let fraction = scheduler.map.fraction
            if let onProgress { DispatchQueue.main.async { onProgress(fraction) } }
        }
    }

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    // MARK: AVAssetResourceLoaderDelegate (runs on `queue`)

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
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
