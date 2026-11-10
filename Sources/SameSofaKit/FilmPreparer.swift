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
    /// Converted films live here until the session ends; anything left from
    /// an earlier run (crash, force quit) is removed on the next start.
    public static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SameSofaPrepared", isDirectory: true)
    }

    public static func removeLeftovers() {
        try? FileManager.default.removeItem(at: directory)
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
            throw FilmPreparerError("That file doesn't look like a film SameSofa can read.")
        }
        var plan: ConversionPlan
        do {
            plan = try MediaPlanner.plan(probe, sidecarSubtitles: sidecar?.path)
        } catch {
            throw FilmPreparerError("That file has no picture or sound SameSofa can find.")
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
        process.arguments = plan.ffmpegArguments(input: input.path, output: output.path)
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
                        self.onProgress?(1, self.progress.speed)
                        completion(.success(self.output))
                    } else {
                        Log.debug("ffmpeg failed (\(status)): \(message)")
                        self.discardOutput()
                        let last = message.split(separator: "\n").last.map(String.init) ?? "exit code \(status)"
                        completion(.failure(FilmPreparerError("Couldn't convert the film (\(last)).")))
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
