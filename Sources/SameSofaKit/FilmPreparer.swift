import AVFoundation
import Foundation
import SameSofaCore

/// The bundled FFmpeg helper programs (LGPL, built by scripts/build-ffmpeg.sh).
/// They run as separate processes; nothing from FFmpeg is linked into SameSofa.
public struct FFmpegTools: Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL

    public init(directory: URL) {
        ffmpeg = directory.appendingPathComponent("ffmpeg")
        ffprobe = directory.appendingPathComponent("ffprobe")
    }

    var exists: Bool {
        FileManager.default.isExecutableFile(atPath: ffmpeg.path) && FileManager.default.isExecutableFile(atPath: ffprobe.path)
    }

    /// Finds the helpers: `SAMESOFA_FFMPEG_DIR`, then the app bundle
    /// (Contents/Helpers), then Vendor/FFmpeg/bin of a source checkout
    /// (for `swift run` and the integration test).
    public static func locate() -> FFmpegTools? {
        var candidates: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["SAMESOFA_FFMPEG_DIR"] {
            candidates.append(URL(fileURLWithPath: dir))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers"))
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("Vendor/FFmpeg/bin"))
            dir.deleteLastPathComponent()
        }
        return candidates.lazy.map(FFmpegTools.init(directory:)).first { $0.exists }
    }
}

/// What the host's film needs before it can be shared.
public enum FilmCheck {
    /// An MP4/MOV that macOS plays: share the original bytes.
    case shareAsIs
    /// Convert (remux or transcode) to MP4 first.
    case convert(ConversionPlan, FFmpegTools)
}

public struct FilmPreparerError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Turns a film AVFoundation can't play into an MP4 it can, with the ffmpeg
/// helper, writing to a temporary file. Copies streams macOS already decodes
/// and re-encodes only the rest (see MediaPlanner).
public final class FilmPreparer {
    static var parentDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SameSofaPrepared", isDirectory: true)
    }

    /// Converted films live here (one folder per running copy of the app)
    /// until the session ends; anything left by a copy that is no longer
    /// running (crash, force quit) is removed on the next start.
    public static var directory: URL {
        parentDirectory.appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
    }

    public static func removeLeftovers() {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        for folder in (try? fm.contentsOfDirectory(atPath: parentDirectory.path)) ?? [] {
            // Another copy of SameSofa that is still running keeps its films.
            if let pid = Int32(folder), pid > 0, kill(pid, 0) == 0 || errno == EPERM { continue }
            try? fm.removeItem(at: parentDirectory.appendingPathComponent(folder))
        }
    }

    /// A same-named .srt next to the film, if any.
    static func sidecarSubtitles(for film: URL) -> URL? {
        let base = film.deletingPathExtension()
        for ext in ["srt", "SRT"] {
            let candidate = base.appendingPathExtension(ext)
            if candidate != film, FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Looks at the film (AVFoundation and ffprobe) and decides what to do.
    public static func inspect(_ film: URL, tools: FFmpegTools? = FFmpegTools.locate()) async throws -> FilmCheck {
        let playable = (try? await AVURLAsset(url: film).load(.isPlayable)) ?? false
        let sidecar = sidecarSubtitles(for: film)
        guard let tools else {
            if playable { return .shareAsIs }
            throw FilmPreparerError("This copy of SameSofa can't convert films (its FFmpeg helper is missing). Try an MP4 or MOV file.")
        }
        let probe: ProbeResult
        do {
            probe = try await Self.probe(film, tools: tools)
        } catch {
            if playable && sidecar == nil { return .shareAsIs }
            throw FilmPreparerError("That file doesn't look like a film SameSofa can read. Pick the film file itself (MP4, MOV, MKV, AVI and similar), or try another copy of it.")
        }
        var plan: ConversionPlan
        do {
            plan = try MediaPlanner.plan(probe, sidecarSubtitles: sidecar?.path)
        } catch {
            throw FilmPreparerError("That file has no picture or sound SameSofa can find. Try another copy of the film.")
        }
        // B-frames without reordering information (or other scrambled
        // presentation times) play out of order in AVFoundation.
        if plan.wantsTimestampCheck, let report = await checkTimestamps(film, duration: probe.duration, tools: tools) {
            Log.debug("timestamp check for \(film.lastPathComponent): \(report.backwardSteps) of \(report.frames) frames out of order")
            if report.isDamaged {
                plan.repairVideoTimestamps = true
                if let tail = await timestampTail(film, duration: probe.duration, tools: tools) {
                    plan.timestampTail = tail.corrections
                    plan.timestampBase = tail.base
                }
                plan.needsConversion = true
                plan.notes.append("video timestamps contradict the picture order (\(report.backwardSteps) of \(report.frames) frames): rebuilding them")
            }
        }
        Log.debug("film plan for \(film.lastPathComponent) [\(probe.formatName)]: \(plan.notes.joined(separator: "; ")) -> \(plan.needsConversion ? "convert" : "as is")")
        if !plan.needsConversion {
            if playable { return .shareAsIs }
            // An MP4/MOV macOS refuses as it is: rewrapping usually fixes it (e.g. HEVC labelled hev1).
            plan.needsConversion = true
        }
        return .convert(plan, tools)
    }

    /// Runs ffprobe and parses its JSON.
    public static func probe(_ film: URL, tools: FFmpegTools) async throws -> ProbeResult {
        let args = ["-v", "error", "-analyzeduration", "20000000", "-probesize", "50000000",
                    "-show_format", "-show_streams", "-of", "json", film.path]
        let data = try await run(tools.ffprobe, args, timeout: 60)
        return try ProbeResult.parse(ffprobeJSON: data)
    }

    /// Decodes three short stretches (start, middle, towards the end) with
    /// FFmpeg, which orders pictures by the bitstream, and compares that order
    /// with the file's presentation times. nil when it could not be checked.
    public static func checkTimestamps(_ film: URL, duration: Double, tools: FFmpegTools) async -> TimestampReport? {
        var intervals = ["%+#160"]
        if duration > 20 { intervals.append(String(format: "%.0f%%+#160", duration * 0.5)) }
        if duration > 60 { intervals.append(String(format: "%.0f%%+#160", duration * 0.9)) }
        let args = ["-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts", "-of", "csv=p=0",
                    "-read_intervals", intervals.joined(separator: ","), film.path]
        guard let data = try? await run(tools.ffprobe, args, timeout: 90) else { return nil }
        let report = TimestampReport.parse(ffprobeFrameTimes: String(decoding: data, as: UTF8.self))
        return report.frames > 0 ? report : nil
    }

    /// Exact presentation times for the film's last samples (see
    /// TimestampTail), and the decode time of the first sample FFmpeg will
    /// copy. nil when they could not be worked out; the repair then leaves
    /// the last frames as dts2pts made them, which the validation rejects.
    static func timestampTail(_ film: URL, duration: Double, tools: FFmpegTools) async -> (base: Int64, corrections: [TimestampTail.Correction])? {
        func lines(_ data: Data) -> [[Substring]] {
            String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        }
        // The reorder delay dts2pts uses, in frames: let it write the film's first samples and look at them.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let head = directory.appendingPathComponent("head-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: head) }
        let headArgs = ["-v", "error", "-y", "-i", film.path, "-map", "0:v:0", "-c", "copy", "-bsf:v", "dts2pts", "-frames:v", "48", "-f", "mp4", head.path]
        let packetArgs = ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts,dts", "-of", "csv=p=0"]
        guard (try? await run(tools.ffmpeg, headArgs, timeout: 60)) != nil,
              let headData = try? await run(tools.ffprobe, packetArgs + [head.path], timeout: 60) else { return nil }
        let headSamples: [TimestampTail.Sample] = lines(headData).compactMap { fields in
            guard fields.count >= 2, let pts = Int64(fields[0]), let dts = Int64(fields[1]) else { return nil }
            return TimestampTail.Sample(pts: pts, dts: dts)
        }
        guard let delay = TimestampTail.reorderDelay(head: headSamples), delay > 0 else { return nil }
        // The first sample FFmpeg copies: the first key frame (anything before it is dropped).
        let firstArgs = ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=dts,flags", "-of", "csv=p=0",
                         "-read_intervals", "%+#64", film.path]
        guard let firstData = try? await run(tools.ffprobe, firstArgs, timeout: 60) else { return nil }
        var base: Int64?
        for fields in lines(firstData) where fields.count >= 2 {
            guard let dts = Int64(fields[0]) else { return nil }
            if fields[1].contains("K") { base = dts; break }
        }
        guard let base else { return nil }
        // The film's last seconds: samples in decode order, pictures in the decoder's display order.
        let tailArgs = ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts,dts:frame=pts", "-of", "csv=p=1",
                        "-read_intervals", String(format: "%.0f%%", max(0, duration - 4)), film.path]
        guard let tailData = try? await run(tools.ffprobe, tailArgs, timeout: 90) else { return nil }
        var order: [Int64] = [], decodeTimes = Set<Int64>()
        for fields in lines(tailData) where fields.count >= 2 {
            switch fields[0] {
            case "packet":
                // Only the plain form of the defect (presentation time = decode time) can be mapped back to samples.
                guard fields.count >= 3, let pts = Int64(fields[1]), let dts = Int64(fields[2]), pts == dts else { return nil }
                decodeTimes.insert(dts)
            case "frame":
                if let pts = Int64(fields[1]) { order.append(pts) }
            default: break
            }
        }
        guard order.count >= 8, Set(order).isSubset(of: decodeTimes) else { return nil }
        // dts2pts makes up more than the last `delay` times: everything it still held when the
        // film ended. Correcting further back is harmless (the times are the ones it gives
        // anyway), but the first pictures of the stretch may depend on what came before it.
        let corrections = TimestampTail.corrections(outputOrder: order, delayFrames: delay, count: min(64, order.count / 2))
        return corrections.isEmpty ? nil : (base, corrections)
    }

    /// The repaired film's last seconds: the decoder's order agrees with the
    /// presentation times (no step back, no repeat), and the last samples'
    /// times are exactly what the repair should have produced.
    static func tailIsInOrder(_ film: URL, duration: Double, tools: FFmpegTools) async -> Bool {
        let args = ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts,dts:frame=pts", "-of", "csv=p=1",
                    "-read_intervals", String(format: "%.0f%%", max(0, duration - 4)), film.path]
        guard let data = try? await run(tools.ffprobe, args, timeout: 90) else { return false }
        var frameTimes = "", samples: [TimestampTail.Sample] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            if fields.count >= 3, fields[0] == "packet", let pts = Int64(fields[1]), let dts = Int64(fields[2]) {
                samples.append(TimestampTail.Sample(pts: pts, dts: dts))
            } else if fields.count >= 2, fields[0] == "frame" {
                frameTimes += fields[1] + "\n"
            }
        }
        let report = TimestampReport.parse(ffprobeFrameTimes: frameTimes, repeatsCount: true)
        guard report.frames > 0, report.backwardSteps == 0 else { return false }
        return TimestampTail.tailIsConsistent(samples)
    }

    /// After a timestamp repair: is the result really in order?
    static func repairIsValid(input: URL, output: URL, duration: Double, tools: FFmpegTools) async -> Bool {
        if ProcessInfo.processInfo.environment["SAMESOFA_TEST_REJECT_REPAIR"] == "1" { return false }
        // 1. FFmpeg's decoder agrees with the new presentation times.
        guard let frames = await checkTimestamps(output, duration: duration, tools: tools), frames.frames >= 12, frames.backwardSteps == 0 else {
            Log.debug("repair check: decoder order still disagrees")
            return false
        }
        guard await tailIsInOrder(output, duration: duration, tools: tools) else {
            Log.debug("repair check: the last frames are out of order")
            return false
        }
        // 2. Samples: unique presentation times, never before their decode time.
        let packetArgs = ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts,dts", "-of", "csv=p=0",
                          "-read_intervals", "%+#600", output.path]
        guard let packetData = try? await run(tools.ffprobe, packetArgs, timeout: 60) else { return false }
        let packets = PacketTimesReport.parse(ffprobePacketTimes: String(decoding: packetData, as: UTF8.self))
        guard packets.isSane, packets.largestReorder <= 16 else {
            Log.debug("repair check: sample times not sane (\(packets))")
            return false
        }
        // 3. No frame went missing.
        func frameCount(_ file: URL) async -> Int? {
            let args = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=nb_frames", "-of", "csv=p=0", file.path]
            guard let data = try? await run(tools.ffprobe, args, timeout: 60) else { return nil }
            return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let before = await frameCount(input), let after = await frameCount(output), before != after {
            Log.debug("repair check: \(before) frames in, \(after) out")
            return false
        }
        // 4. AVFoundation decodes the start, the middle and the end with rising presentation times.
        let asset = AVURLAsset(url: output)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return false }
        for start in duration > 30 ? [0, duration / 2, duration - 10] : [0] {
            guard let reader = try? AVAssetReader(asset: asset) else { return false }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            reader.add(out)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: 10, preferredTimescale: 600))
            guard reader.startReading() else { return false }
            var last = -Double.infinity, count = 0
            while let sample = out.copyNextSampleBuffer() {
                guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if time <= last { Log.debug("repair check: AVFoundation frame times not rising at \(time)"); return false }
                last = time
                count += 1
            }
            guard reader.status == .completed, count > 0 else { return false }
        }
        return true
    }

    private static func run(_ program: URL, _ arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = program
            process.arguments = arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let output = OutputBuffer()
            out.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
            process.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                output.append(out.fileHandleForReading.readDataToEndOfFile())
                let data = output.data
                if p.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: FilmPreparerError("\(program.lastPathComponent) failed (\(p.terminationStatus))"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ chunk: Data) { lock.lock(); buffer.append(chunk); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    // MARK: Converting

    public let input: URL
    public let plan: ConversionPlan
    /// The plan being carried out: `plan`, or its fallback (re-encoding the
    /// video) when a timestamp repair did not hold up.
    public private(set) var activePlan: ConversionPlan
    public let output: URL
    private let tools: FFmpegTools
    private var process: Process?
    private var cancelled = false
    private var progress = FFmpegProgress()
    private var lineBuffer = Data()
    private var errorTail = Data()
    public private(set) var startedAt: Date?

    /// Fraction done (0...1) and speed (x real time), on the main queue.
    public var onProgress: ((Double, Double?) -> Void)?

    public init(input: URL, plan: ConversionPlan, tools: FFmpegTools) {
        self.input = input
        self.plan = plan
        activePlan = plan
        self.tools = tools
        output = Self.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    }

    /// Starts ffmpeg. `completion` runs once on the main queue with the
    /// finished MP4 or an error (`CancellationError` after `cancel()`).
    public func start(completion: @escaping (Result<URL, Error>) -> Void) {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        } catch {
            completion(.failure(error))
            return
        }
        let process = Process()
        process.executableURL = tools.ffmpeg
        let running = activePlan
        process.arguments = running.ffmpegArguments(input: input.path, output: output.path)
        Log.debug("ffmpeg \(process.arguments!.joined(separator: " "))")
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let queue = DispatchQueue(label: "samesofa.preparer")
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            queue.async { self?.consume(chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            queue.async {
                guard let self else { return }
                self.errorTail.append(chunk)
                if self.errorTail.count > 4096 { self.errorTail = self.errorTail.suffix(4096) }
            }
        }
        // Holds on to self until ffmpeg has exited, even if the party let go
        // of it (cancel), so the partial file is always cleaned up.
        process.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            queue.async {
                let status = p.terminationStatus
                let message = String(decoding: self.errorTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.process = nil
                    if self.cancelled {
                        self.discardOutput()
                        completion(.failure(CancellationError()))
                    } else if status == 0, FileManager.default.fileExists(atPath: self.output.path) {
                        guard running.repairVideoTimestamps else {
                            self.onProgress?(1, self.progress.speed)
                            completion(.success(self.output))
                            return
                        }
                        // Rebuilt timestamps are only trusted after checking them.
                        Task {
                            let valid = await Self.repairIsValid(input: self.input, output: self.output, duration: running.duration, tools: self.tools)
                            await MainActor.run {
                                if self.cancelled {
                                    self.discardOutput()
                                    completion(.failure(CancellationError()))
                                } else if valid {
                                    self.onProgress?(1, self.progress.speed)
                                    completion(.success(self.output))
                                } else if let fallback = running.fallbackPlan {
                                    Log.debug("timestamp repair did not validate; re-encoding the video")
                                    self.discardOutput()
                                    self.activePlan = fallback
                                    self.progress = FFmpegProgress()
                                    self.onProgress?(0, nil)
                                    self.start(completion: completion)
                                } else {
                                    self.discardOutput()
                                    completion(.failure(FilmPreparerError("This file's timing information is damaged and couldn't be repaired. Try another copy of the film.")))
                                }
                            }
                        }
                    } else {
                        Log.debug("ffmpeg failed (\(status)): \(message)")
                        self.discardOutput()
                        let last = message.split(separator: "\n").last.map(String.init) ?? "exit code \(status)"
                        completion(.failure(FilmPreparerError("Couldn't convert the film (\(last)). Try another copy of it, or an MP4 or MOV version.")))
                    }
                }
            }
        }
        do {
            try process.run()
            self.process = process
            startedAt = Date()
        } catch {
            completion(.failure(error))
        }
    }

    private func consume(_ chunk: Data) {
        lineBuffer.append(chunk)
        var updated = false
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: lineBuffer[lineBuffer.startIndex..<newline], as: UTF8.self)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            if progress.consume(line: line) { updated = true }
        }
        guard updated else { return }
        let fraction = progress.fraction(duration: plan.duration), speed = progress.speed
        DispatchQueue.main.async { self.onProgress?(fraction, speed) }
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    /// Stops ffmpeg and deletes the partial file.
    public func cancel() {
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        discardOutput()
    }

    public func discardOutput() {
        try? FileManager.default.removeItem(at: output)
    }
}
