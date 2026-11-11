import AVFoundation
import Foundation
import SameSofaCore
import SameSofaKit

// Harder cases for the timestamp repair (see TimestampSuite for the basic ones):
//
//   samesofa-itest --timestamp-edge-suite workdir [--reference-ffmpeg /path/to/ffmpeg]
//
// Container time bases (1/1200000, 1/90000, 1/1000, 1/600), a film that does
// not start at zero, no edit list, uneven and variable frame durations, open
// GOPs, films of one to thirteen frames, and deliberately wrong repairs that
// the validation has to refuse. Every clip carries its frame number in the
// picture, so "in order" is read from what AVFoundation presents.

enum TimestampEdgeSuite {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !ok { failures += 1 }
    }

    struct Clip {
        var name: String
        /// Input options and filter graph of the picture (after the frame counter is added).
        var rate: String
        var seconds: Double
        var filter: String = ""
        var encoder: [String]
        /// Muxer options for the healthy clip.
        var mux: [String] = []
        /// How the damaged copy is made from the healthy one.
        var damage: [String] = ["-bsf:v", "setts=pts=DTS"]
        var damagedExtension = "mp4"
        var damagedMux: [String] = []
        /// The repair must hold up (no falling back to re-encoding).
        var mustRepair = true
        var frames: Int?
    }

    static let x264 = ["-c:v", "libx264", "-preset", "fast", "-bf", "3", "-b_strategy", "1", "-g", "48", "-pix_fmt", "yuv420p"]
    static let x265 = ["-c:v", "libx265", "-preset", "fast", "-x265-params", "bframes=3:b-pyramid=1:keyint=48:log-level=error",
                       "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"]

    static let clips: [Clip] = [
        // The shape of the real file behind the repair: HEVC Main 10, hev1, 24000/1001 fps at
        // 1/1200000, first samples at -100099, -50050, 0, 50050 with every pts equal to its dts.
        Clip(name: "hevc10-1200000", rate: "24000/1001", seconds: 24, encoder: x265, mux: ["-video_track_timescale", "1200000"],
             damage: ["-bsf:v", "setts=ts=DTS+eq(N\\,0)", "-tag:v", "hev1", "-video_track_timescale", "1200000"]),
        Clip(name: "h264-90000", rate: "25", seconds: 12, encoder: x264, mux: ["-video_track_timescale", "90000"],
             damage: ["-bsf:v", "setts=pts=DTS", "-video_track_timescale", "90000"]),
        // 1001/24000 s is 25.025 ticks of 1/600: frame durations of 25 and 26.
        Clip(name: "h264-600", rate: "24000/1001", seconds: 12, encoder: x264, mux: ["-video_track_timescale", "600"],
             damage: ["-bsf:v", "setts=pts=DTS", "-video_track_timescale", "600"]),
        // The whole film five seconds late: FFmpeg moves it back to zero before the filters run.
        Clip(name: "hevc-starts-at-5s", rate: "24000/1001", seconds: 12, encoder: x265,
             damage: ["-bsf:v", "setts=pts=DTS", "-tag:v", "hev1", "-output_ts_offset", "5"]),
        Clip(name: "h264-no-edit-list", rate: "25", seconds: 12, encoder: x264,
             damage: ["-bsf:v", "setts=pts=DTS", "-use_editlist", "0"]),
        // Variable frame rate: 50 fps for eight seconds, then every other frame.
        Clip(name: "h264-variable-rate", rate: "50", seconds: 16, filter: "select='lt(n\\,400)+not(mod(n\\,2))',", encoder: x264 + ["-fps_mode", "vfr"]),
        Clip(name: "h264-open-gop", rate: "25", seconds: 12, encoder: x264 + ["-x264-params", "open-gop=1"]),
        Clip(name: "hevc-closed-gop", rate: "25", seconds: 12,
             encoder: ["-c:v", "libx265", "-preset", "fast", "-x265-params", "bframes=4:b-pyramid=1:keyint=48:open-gop=0:log-level=error",
                       "-pix_fmt", "yuv420p", "-tag:v", "hvc1"]),
        // Other containers: whatever happens, the result has to be right.
        Clip(name: "h264-matroska-1000", rate: "24000/1001", seconds: 12, encoder: x264, damagedExtension: "mkv", mustRepair: false),
        Clip(name: "h264-mpegts-90000", rate: "25", seconds: 12, encoder: x264, damagedExtension: "ts", mustRepair: false),
        // Very short films.
        Clip(name: "h264-40-frames", rate: "25", seconds: 2, encoder: x264, mustRepair: false, frames: 40),
        Clip(name: "h264-13-frames", rate: "25", seconds: 2, encoder: x264, mustRepair: false, frames: 13),
        Clip(name: "h264-3-frames", rate: "25", seconds: 2, encoder: x264, mustRepair: false, frames: 3),
        Clip(name: "h264-2-frames", rate: "25", seconds: 2, encoder: x264, mustRepair: false, frames: 2),
        Clip(name: "h264-1-frame", rate: "25", seconds: 2, encoder: x264, mustRepair: false, frames: 1),
    ]

    static func run(workDirectory: URL, referenceFFmpeg: String, only: String?) -> Never {
        guard let tools = FFmpegTools.locate() else { print("FAIL FFmpeg helper found (run scripts/build-ffmpeg.sh)"); exit(1) }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let counter = "geq=lum='if(between(X,mod(N,64)*10,mod(N,64)*10+9)*lt(Y,180)+between(X,floor(N/64)*10,floor(N/64)*10+9)*gte(Y,180),235,16)':cb=128:cr=128"
        for clip in clips where only == nil || clip.name.contains(only!) {
            let good = workDirectory.appendingPathComponent("edge-good-\(clip.name).mp4")
            let broken = workDirectory.appendingPathComponent("edge-broken-\(clip.name).\(clip.damagedExtension)")
            var make = ["-v", "error", "-y", "-f", "lavfi", "-i", "color=black:s=640x360:r=\(clip.rate):d=\(clip.seconds),\(clip.filter)\(counter)",
                        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(clip.seconds)"] + clip.encoder
            if let frames = clip.frames { make += ["-frames:v", String(frames)] }
            make += ["-c:a", "aac", "-b:a", "128k", "-shortest"] + clip.mux + [good.path]
            TimestampSuite.shell(referenceFFmpeg, make)
            TimestampSuite.shell(referenceFFmpeg, ["-v", "error", "-y", "-i", good.path, "-c", "copy"] + clip.damage + clip.damagedMux + [broken.path])
            let reference = TimestampSuite.presentedFrames(good)
            let expectedFrames = clip.frames ?? reference.count
            check("\(clip.name): reference clip has its frames in order", reference.count == expectedFrames && reference.count > 0
                    && TimestampSuite.outOfOrder(reference) == 0, "\(reference.count) frames")

            // Whatever is decided, it must not throw, hang or produce a film with frames out of order.
            let verdict = TimestampSuite.wait { await Result { try await FilmPreparer.inspect(broken, tools: tools) } }
            guard case .success(let checkResult) = verdict else {
                check("\(clip.name): inspected", false, "\(verdict)")
                continue
            }
            guard case .convert(let plan, _) = checkResult else {
                // Shared as it is: only right when AVFoundation shows it in order (too short to matter otherwise).
                let shown = TimestampSuite.presentedFrames(broken)
                check("\(clip.name): shared as it is only when harmless", reference.count < 25 || TimestampSuite.outOfOrder(shown) == 0,
                      "\(TimestampSuite.outOfOrder(shown)) of \(shown.count) frames step backwards")
                continue
            }
            if clip.mustRepair {
                check("\(clip.name): damage detected, repair planned with the last frames worked out",
                      plan.repairVideoTimestamps && plan.isRemuxOnly && !plan.timestampTail.isEmpty, plan.notes.joined(separator: "; "))
            }
            guard let result = TimestampSuite.prepare(broken, plan: plan, tools: tools) else { check("\(clip.name): conversion runs", false); continue }
            let fixed = TimestampSuite.presentedFrames(result.url)
            let copied = result.plan.isRemuxOnly
            if clip.mustRepair { check("\(clip.name): repair validated without falling back", copied && result.plan.repairVideoTimestamps) }
            let gaps = zip(fixed, fixed.dropFirst()).filter { $1.number != $0.number + 1 }.map { "\($0.number)->\($1.number)" }
            // A copy keeps every frame. Re-encoding (the fallback) may lose a few frames, as in the basic suite.
            check("\(clip.name): result presents every frame in order", TimestampSuite.outOfOrder(fixed) == 0
                    && (copied ? fixed.count == reference.count && gaps.isEmpty : abs(fixed.count - reference.count) <= 4),
                  "\(fixed.count) of \(reference.count) frames (\(fixed.first?.number ?? -1)...\(fixed.last?.number ?? -1)\(gaps.isEmpty ? "" : ", gaps " + gaps.joined(separator: " "))), \(TimestampSuite.outOfOrder(fixed)) backwards, \(copied ? (result.plan.repairVideoTimestamps ? "repaired" : "copied") : "re-encoded")")
            if copied, fixed.count == reference.count, let first = fixed.first, let referenceFirst = reference.first {
                let worst = zip(fixed, reference).map { abs(($0.time - first.time) - ($1.time - referenceFirst.time)) }.max() ?? 1
                check("\(clip.name): every frame is back at its original time", worst < 0.0005, String(format: "largest difference %.4f ms", worst * 1000))
            }
            try? FileManager.default.removeItem(at: result.url)

            // Wrong repairs must be refused (and the film re-encoded instead).
            guard clip.mustRepair, plan.timestampTail.count >= 4, clip.name.contains("1200000") || clip.name.contains("90000") else { continue }
            let tail = plan.timestampTail
            let step = tail[tail.count - 1].decodeTime - tail[tail.count - 2].decodeTime
            var wrong: [(String, [TimestampTail.Correction])] = []
            wrong.append(("last frames left as dts2pts makes them up", []))
            wrong.append(("corrections given to the neighbouring samples",
                          tail.indices.map { .init(decodeTime: tail[$0].decodeTime, presentationTime: tail[($0 + 1) % tail.count].presentationTime) }))
            wrong.append(("last frames one frame late", tail.map { .init(decodeTime: $0.decodeTime, presentationTime: $0.presentationTime + step) }))
            var tick = tail
            tick[tick.count - 1].presentationTime += 1
            wrong.append(("one frame one tick late", tick))
            for (what, corrections) in wrong {
                var bad = plan
                bad.timestampTail = corrections
                guard let outcome = TimestampSuite.prepare(broken, plan: bad, tools: tools) else { check("\(clip.name): wrong repair (\(what)) handled", false); continue }
                let frames = TimestampSuite.presentedFrames(outcome.url)
                check("\(clip.name): wrong repair refused: \(what)", outcome.plan.reencodesVideo && !outcome.plan.repairVideoTimestamps)
                check("\(clip.name): ... and the film is still right", TimestampSuite.outOfOrder(frames) == 0 && abs(frames.count - reference.count) <= 4,
                      "\(frames.count) of \(reference.count) frames")
                try? FileManager.default.removeItem(at: outcome.url)
            }
        }
        print("SUMMARY \(failures == 0 ? "all timestamp edge checks passed" : "\(failures) timestamp edge checks FAILED")")
        exit(failures == 0 ? 0 : 1)
    }
}
