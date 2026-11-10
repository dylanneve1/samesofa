import AVFoundation
import Foundation
import SameSofaCore
import SameSofaKit

// Films whose video has B-frames but no reordering information (every
// presentation time equals the decode time) play with frames out of order in
// AVFoundation. This suite builds such files and checks detection and repair:
//
//   samesofa-itest --timestamp-suite workdir --reference-ffmpeg /path/to/ffmpeg [--healthy a.mkv,b.mp4]
//
// The test clips carry the frame number in the picture (two white bars whose
// positions encode it), so the order AVFoundation presents frames in can be
// read back numerically. The reference FFmpeg (with libx264/libx265) only
// makes the clips; detection and repair use SameSofa's own helper.

enum TimestampSuite {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !ok { failures += 1 }
    }

    static func wait<T>(_ operation: @escaping () async -> T) -> T {
        var result: T?
        Task { result = await operation() }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return result!
    }

    @discardableResult
    static func shell(_ program: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Frame numbers read from the picture, in the order AVFoundation presents them, with their times.
    static func presentedFrames(_ url: URL) -> [(time: Double, number: Int)] {
        let asset = AVURLAsset(url: url)
        guard let track = wait({ try? await asset.loadTracks(withMediaType: .video).first }),
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }
        var frames: [(Double, Int)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { continue }
            let width = CVPixelBufferGetWidthOfPlane(image, 0), height = CVPixelBufferGetHeightOfPlane(image, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            func bar(row: Int) -> Int {
                // Centre of the bright run on this row, in units of bar widths (a 64th of the width).
                let line = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                var sum = 0, count = 0
                for x in 0..<width where line[x] > 128 { sum += x; count += 1 }
                guard count > 0 else { return -1 }
                return (sum / count) * 64 / width
            }
            let top = bar(row: height / 4), bottom = bar(row: height * 3 / 4)
            guard top >= 0, bottom >= 0 else { continue }
            frames.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, top + 64 * bottom))
        }
        return frames.sorted { $0.0 < $1.0 }
    }

    static func outOfOrder(_ frames: [(time: Double, number: Int)]) -> Int {
        zip(frames, frames.dropFirst()).filter { $1.number <= $0.number }.count
    }

    static func audioStart(_ url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = wait({ try? await asset.loadTracks(withMediaType: .audio).first }),
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer() else { return nil }
        return CMSampleBufferGetPresentationTimeStamp(sample).seconds
    }

    static func prepare(_ film: URL, plan: ConversionPlan, tools: FFmpegTools) -> (url: URL, plan: ConversionPlan)? {
        let preparer = FilmPreparer(input: film, plan: plan, tools: tools)
        var outcome: Result<URL, Error>?
        preparer.start { outcome = $0 }
        while outcome == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard case .success(let url) = outcome else { return nil }
        return (url, preparer.activePlan)
    }

    static func run(workDirectory: URL, referenceFFmpeg: String, healthy: [URL]) -> Never {
        guard let tools = FFmpegTools.locate() else { print("FAIL FFmpeg helper found (run scripts/build-ffmpeg.sh)"); exit(1) }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let counter = "geq=lum='if(between(X,mod(N,64)*10,mod(N,64)*10+9)*lt(Y,180)+between(X,floor(N/64)*10,floor(N/64)*10+9)*gte(Y,180),235,16)':cb=128:cr=128"
        let clips: [(name: String, rate: String, encoder: [String], brokenTag: String)] = [
            ("hevc", "24000/1001", ["-c:v", "libx265", "-preset", "fast", "-x265-params", "bframes=3:b-pyramid=1:keyint=48:log-level=error",
                                    "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"], "hev1"),
            ("h264", "25", ["-c:v", "libx264", "-preset", "fast", "-bf", "3", "-b_strategy", "1", "-g", "50", "-pix_fmt", "yuv420p"], "avc1"),
        ]
        for clip in clips {
            let good = workDirectory.appendingPathComponent("good-\(clip.name).mp4")
            let broken = workDirectory.appendingPathComponent("broken-\(clip.name).mp4")
            // A correct clip with B-frames and sound, then the same streams with pts := dts.
            shell(referenceFFmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "color=black:s=640x360:r=\(clip.rate):d=40,\(counter)",
                                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=40"] + clip.encoder
                    + ["-c:a", "aac", "-b:a", "128k", "-shortest", good.path])
            shell(tools.ffmpeg.path, ["-v", "error", "-y", "-i", good.path, "-c", "copy", "-bsf:v", "setts=pts=DTS", "-tag:v", clip.brokenTag, broken.path])
            // AVFoundation does not open "hev1" files at all; for looking at the defect itself, label it "hvc1".
            let visible = workDirectory.appendingPathComponent("broken-visible-\(clip.name).mp4")
            shell(tools.ffmpeg.path, ["-v", "error", "-y", "-i", good.path, "-c", "copy", "-bsf:v", "setts=pts=DTS",
                                      "-tag:v", clip.name == "hevc" ? "hvc1" : "avc1", visible.path])
            let reference = presentedFrames(good)
            check("\(clip.name): reference clip has its frames in order", reference.count > 900 && outOfOrder(reference) == 0, "\(reference.count) frames")
            let damaged = presentedFrames(visible)
            check("\(clip.name): the defect is reproduced (AVFoundation shows the stripped clip out of order)", outOfOrder(damaged) > damaged.count / 10,
                  "\(outOfOrder(damaged)) of \(damaged.count) frames step backwards")

            // Healthy clip: left alone.
            if case .success(let verdict) = wait({ await Result { try await FilmPreparer.inspect(good, tools: tools) } }) {
                if case .shareAsIs = verdict { check("\(clip.name): healthy clip is shared as it is", true) } else { check("\(clip.name): healthy clip is shared as it is", false, "wants conversion") }
            } else { check("\(clip.name): healthy clip inspected", false) }

            // Damaged clip: detected, repaired by copying, validated.
            guard case .success(.convert(let plan, _)) = wait({ await Result { try await FilmPreparer.inspect(broken, tools: tools) } }) else {
                check("\(clip.name): damaged clip is detected", false, "not sent to conversion")
                continue
            }
            check("\(clip.name): damaged clip is detected", plan.repairVideoTimestamps, plan.notes.joined(separator: "; "))
            check("\(clip.name): repair copies the streams (no re-encoding)", plan.isRemuxOnly)
            guard let repaired = prepare(broken, plan: plan, tools: tools) else { check("\(clip.name): repair runs", false); continue }
            check("\(clip.name): repair validated without falling back", repaired.plan.repairVideoTimestamps && repaired.plan.isRemuxOnly)
            let fixed = presentedFrames(repaired.url)
            check("\(clip.name): repaired clip presents every frame in order", fixed.count == reference.count && outOfOrder(fixed) == 0
                    && zip(fixed, fixed.dropFirst()).allSatisfy { $1.number == $0.number + 1 },
                  "\(fixed.count) frames, \(outOfOrder(fixed)) backwards")
            let worstShift = zip(fixed, reference).map { abs($0.time - $1.time) }.max() ?? 1
            check("\(clip.name): every frame is back at its original time", fixed.count == reference.count && worstShift < 0.0005
                    && zip(fixed, reference).allSatisfy { $0.number == $1.number }, String(format: "largest difference %.4f ms", worstShift * 1000))
            if let a = audioStart(good), let b = audioStart(repaired.url) {
                check("\(clip.name): sound starts where it did (A/V offset unchanged)", abs(a - b) < 0.0005, String(format: "%.4f s vs %.4f s", a, b))
            } else { check("\(clip.name): sound readable", false) }
            if case .success(let again) = wait({ await Result { try await FilmPreparer.inspect(repaired.url, tools: tools) } }), case .shareAsIs = again {
                check("\(clip.name): repaired clip passes the detector", true)
            } else { check("\(clip.name): repaired clip passes the detector", false) }
            try? FileManager.default.removeItem(at: repaired.url)

            // If the repair cannot be validated, the picture is re-encoded instead.
            setenv("SAMESOFA_TEST_REJECT_REPAIR", "1", 1)
            if let converted = prepare(broken, plan: plan, tools: tools) {
                let frames = presentedFrames(converted.url)
                check("\(clip.name): fallback re-encodes when the repair doesn't validate", converted.plan.reencodesVideo && !converted.plan.repairVideoTimestamps)
                check("\(clip.name): fallback result presents every frame in order", abs(frames.count - reference.count) <= 4 && outOfOrder(frames) == 0, "\(frames.count) of \(reference.count) frames")
                try? FileManager.default.removeItem(at: converted.url)
            } else { check("\(clip.name): fallback runs", false) }
            unsetenv("SAMESOFA_TEST_REJECT_REPAIR")
        }
        // No false alarms on healthy films.
        for film in healthy {
            guard let probe = wait({ try? await FilmPreparer.probe(film, tools: tools) }) else { check("\(film.lastPathComponent): probed", false); continue }
            let report = wait { await FilmPreparer.checkTimestamps(film, duration: probe.duration, tools: tools) }
            check("\(film.lastPathComponent): no false alarm", report.map { !$0.isDamaged } ?? true,
                  report.map { "\($0.backwardSteps) of \($0.frames) frames out of order" } ?? "no video to check")
        }
        print("SUMMARY \(failures == 0 ? "all timestamp checks passed" : "\(failures) timestamp checks FAILED")")
        exit(failures == 0 ? 0 : 1)
    }
}

extension Result where Failure == Error {
    init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
