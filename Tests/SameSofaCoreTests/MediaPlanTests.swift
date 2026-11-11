import Foundation
import XCTest
@testable import SameSofaCore

final class MediaPlanTests: XCTestCase {
    private func video(_ index: Int, _ codec: String, pix: String = "yuv420p", profile: String? = nil,
                       size: (Int, Int) = (1920, 1080), fps: Double = 24, bitRate: Int? = nil) -> ProbedStream {
        var s = ProbedStream(index: index, kind: .video, codec: codec)
        s.pixelFormat = pix
        s.profile = profile
        s.width = size.0
        s.height = size.1
        s.frameRate = fps
        s.bitRate = bitRate
        s.fieldOrder = "progressive"
        return s
    }

    private func audio(_ index: Int, _ codec: String, channels: Int = 2, isDefault: Bool = false) -> ProbedStream {
        var s = ProbedStream(index: index, kind: .audio, codec: codec)
        s.channels = channels
        s.sampleRate = 48_000
        s.isDefault = isDefault
        return s
    }

    private func subtitle(_ index: Int, _ codec: String) -> ProbedStream {
        ProbedStream(index: index, kind: .subtitle, codec: codec)
    }

    private func probe(_ format: String, _ streams: [ProbedStream]) -> ProbeResult {
        ProbeResult(formatName: format, duration: 600, streams: streams)
    }

    // MARK: Remux (copy) paths

    func testMKVWithH264AndAACIsRemuxOnly() throws {
        let plan = try MediaPlanner.plan(probe("matroska,webm", [video(0, "h264", profile: "High"), audio(1, "aac")]))
        XCTAssertTrue(plan.needsConversion)
        XCTAssertTrue(plan.isRemuxOnly)
        XCTAssertEqual(plan.video, .init(stream: 0, action: .copy(tagHvc1: false)))
        XCTAssertEqual(plan.audio, .init(stream: 1, action: .copy))
        XCTAssertFalse(plan.regenerateTimestamps)
    }

    func testHEVC10BitWithAC3IsCopiedAndTaggedHvc1() throws {
        let plan = try MediaPlanner.plan(probe("matroska,webm", [video(0, "hevc", pix: "yuv420p10le", profile: "Main 10"), audio(1, "ac3", channels: 6)]))
        XCTAssertEqual(plan.video?.action, .copy(tagHvc1: true))
        XCTAssertEqual(plan.audio?.action, .copy)
        let args = plan.ffmpegArguments(input: "in.mkv", output: "out.mp4")
        XCTAssertTrue(args.contains("hvc1"))
        XCTAssertFalse(args.contains("hevc_videotoolbox"))
    }

    func testAVIWithH264IsRemuxedWithRegeneratedTimestamps() throws {
        let plan = try MediaPlanner.plan(probe("avi", [video(0, "h264"), audio(1, "ac3")]))
        XCTAssertTrue(plan.isRemuxOnly)
        XCTAssertTrue(plan.regenerateTimestamps)
        let args = plan.ffmpegArguments(input: "in.avi", output: "out.mp4")
        let genpts = try XCTUnwrap(args.firstIndex(of: "+genpts"))
        XCTAssertLessThan(genpts, try XCTUnwrap(args.firstIndex(of: "-i")), "-fflags is an input option")
    }

    func testPlayableMP4NeedsNothing() throws {
        let plan = try MediaPlanner.plan(probe("mov,mp4,m4a,3gp,3g2,mj2", [video(0, "h264"), audio(1, "aac")]))
        XCTAssertFalse(plan.needsConversion)
    }

    func testMP4WithSidecarSubtitlesIsRemuxed() throws {
        let plan = try MediaPlanner.plan(probe("mov,mp4,m4a,3gp,3g2,mj2", [video(0, "h264"), audio(1, "aac")]), sidecarSubtitles: "/films/Film.srt")
        XCTAssertTrue(plan.needsConversion)
        XCTAssertTrue(plan.isRemuxOnly)
        XCTAssertEqual(plan.subtitles, .sidecar(path: "/films/Film.srt"))
        let args = plan.ffmpegArguments(input: "/films/Film.mp4", output: "out.mp4")
        XCTAssertEqual(args.filter { $0 == "-i" }.count, 2)
        XCTAssertTrue(args.contains("1:0"))
        XCTAssertTrue(args.contains("mov_text"))
    }

    // MARK: Transcode paths

    func testXvidInAVIIsReencodedToH264() throws {
        let plan = try MediaPlanner.plan(probe("avi", [video(0, "mpeg4", profile: "Advanced Simple Profile", size: (720, 400), fps: 25, bitRate: 1_200_000), audio(1, "mp3")]))
        guard case .encode(let codec, let tenBit, let bitRate, let gop, let deinterlace)? = plan.video?.action else {
            return XCTFail("expected encode, got \(String(describing: plan.video))")
        }
        XCTAssertEqual(codec, .h264)
        XCTAssertFalse(tenBit)
        XCTAssertEqual(bitRate, 2_500_000, "small films get the 2.5 Mbit/s floor")
        XCTAssertEqual(gop, 50)
        XCTAssertFalse(deinterlace)
        XCTAssertEqual(plan.audio?.action, .encode(codec: .aac, channels: 2, bitRate: 256_000), "AVPlayer won't play MP3 inside MP4")
        XCTAssertFalse(plan.isRemuxOnly)
        let args = plan.ffmpegArguments(input: "in.avi", output: "out.mp4")
        XCTAssertTrue(args.contains("h264_videotoolbox"))
        XCTAssertFalse(args.contains { $0.contains("libx264") })
    }

    func testVP9AndOpusAreReencoded() throws {
        let plan = try MediaPlanner.plan(probe("matroska,webm", [video(0, "vp9", size: (1280, 720), fps: 30), audio(1, "opus")]))
        guard case .encode(.h264, false, let bitRate, 60, false)? = plan.video?.action else {
            return XCTFail("expected 8-bit H.264 encode, got \(String(describing: plan.video))")
        }
        XCTAssertEqual(Double(bitRate), 10_000_000 * pow(1280.0 * 720 / (1920 * 1080), 0.75), accuracy: 1)
        XCTAssertEqual(plan.audio?.action, .encode(codec: .aac, channels: 2, bitRate: 256_000))
    }

    func testTenBitAndHDRAndUHDGoToHEVC() throws {
        var hdr = video(0, "vp9", pix: "yuv420p10le", size: (3840, 2160))
        hdr.colorTransfer = "smpte2084"
        let plan = try MediaPlanner.plan(probe("matroska,webm", [hdr, audio(1, "eac3", channels: 6)]))
        guard case .encode(.hevc, true, _, _, _)? = plan.video?.action else { return XCTFail("\(String(describing: plan.video))") }
        let args = plan.ffmpegArguments(input: "in.mkv", output: "out.mp4")
        XCTAssertTrue(args.contains("main10"))
        XCTAssertTrue(args.contains("p010le"))
        XCTAssertTrue(args.contains("hvc1"))
        XCTAssertEqual(plan.audio?.action, .copy)

        let uhd = try MediaPlanner.plan(probe("matroska,webm", [video(0, "av1", size: (3840, 2160))]))
        guard case .encode(.hevc, false, _, _, _)? = uhd.video?.action else { return XCTFail("\(String(describing: uhd.video))") }
    }

    func testH264High10IsReencoded() throws {
        let plan = try MediaPlanner.plan(probe("matroska,webm", [video(0, "h264", pix: "yuv420p10le", profile: "High 10"), audio(1, "aac")]))
        guard case .encode(.hevc, true, _, _, _)? = plan.video?.action else { return XCTFail("\(String(describing: plan.video))") }
    }

    func testInterlacedSourceIsDeinterlaced() throws {
        var s = video(0, "mpeg2video", size: (1920, 1080), fps: 25)
        s.fieldOrder = "tt"
        let plan = try MediaPlanner.plan(probe("mpegts", [s, audio(1, "mp2")]))
        guard case .encode(_, _, _, _, true)? = plan.video?.action else { return XCTFail("\(String(describing: plan.video))") }
        XCTAssertTrue(plan.ffmpegArguments(input: "a.ts", output: "b.mp4").contains { $0.hasPrefix("yadif") })
        XCTAssertEqual(plan.audio?.action, .encode(codec: .aac, channels: 2, bitRate: 256_000))
    }

    func testAudioDecisions() {
        // Whatever AVPlayer plays from an MP4 is never re-encoded.
        for codec in ["aac", "ac3", "eac3", "alac", "flac"] {
            XCTAssertEqual(MediaPlanner.audioAction(audio(0, codec, channels: 6)), .copy, codec)
            XCTAssertEqual(MediaPlanner.audioAction(audio(0, codec, channels: 8)), .copy, codec)
        }
        // Lossy sources: Apple's AAC encoder at transparent rates, layout kept up to 5.1.
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "mp3")), .encode(codec: .aac, channels: 2, bitRate: 256_000))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "opus")), .encode(codec: .aac, channels: 2, bitRate: 256_000))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "vorbis", channels: 1)), .encode(codec: .aac, channels: 1, bitRate: 128_000))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "dts", channels: 6)), .encode(codec: .aac, channels: 6, bitRate: 448_000))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "opus", channels: 6)), .encode(codec: .aac, channels: 6, bitRate: 448_000))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "dts", channels: 8)), .encode(codec: .aac, channels: 6, bitRate: 640_000))
        // Lossless sources: Apple Lossless in stereo, AAC at the top rates for surround.
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "pcm_s16le")), .encode(codec: .alac, channels: 2, bitRate: 0))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "pcm_s24le", channels: 1)), .encode(codec: .alac, channels: 1, bitRate: 0))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "truehd")), .encode(codec: .alac, channels: 2, bitRate: 0))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "truehd", channels: 6)), .encode(codec: .aac, channels: 6, bitRate: 448_000))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "truehd", channels: 8)), .encode(codec: .aac, channels: 6, bitRate: 640_000))
        var dtsMA = audio(0, "dts")
        dtsMA.profile = "DTS-HD MA"
        XCTAssertEqual(MediaPlanner.audioAction(dtsMA), .encode(codec: .alac, channels: 2, bitRate: 0))
        var highRate = audio(0, "pcm_s24le")
        highRate.sampleRate = 192_000
        XCTAssertEqual(MediaPlanner.audioAction(highRate), .encode(codec: .aac, channels: 2, bitRate: 256_000))
    }

    func testAudioEncoderArguments() throws {
        let aac = try MediaPlanner.plan(probe("matroska,webm", [video(0, "h264"), audio(1, "dts", channels: 6)]))
        let aacArgs = aac.ffmpegArguments(input: "a.mkv", output: "b.mp4")
        XCTAssertTrue(aacArgs.contains("aac_at"), "Apple's AAC encoder, not FFmpeg's")
        XCTAssertEqual(aacArgs[try XCTUnwrap(aacArgs.firstIndex(of: "-b:a")) + 1], "448000")
        XCTAssertEqual(aacArgs[try XCTUnwrap(aacArgs.firstIndex(of: "-ac")) + 1], "6")
        XCTAssertFalse(aacArgs.contains { $0.contains("loudnorm") || $0.contains("volume") }, "level untouched")
        let alac = try MediaPlanner.plan(probe("matroska,webm", [video(0, "h264"), audio(1, "pcm_s24le")]))
        XCTAssertTrue(alac.ffmpegArguments(input: "a.mkv", output: "b.mp4").contains("alac"))
        let flac = try MediaPlanner.plan(probe("matroska,webm", [video(0, "h264"), audio(1, "flac", channels: 6)]))
        XCTAssertTrue(flac.isRemuxOnly)
        XCTAssertTrue(flac.ffmpegArguments(input: "a.mkv", output: "b.mp4").contains("-strict"))
        var high = audio(1, "vorbis")
        high.sampleRate = 96_000
        let resampled = try MediaPlanner.plan(probe("matroska,webm", [video(0, "h264"), high]))
        XCTAssertTrue(resampled.ffmpegArguments(input: "a.mkv", output: "b.mp4").contains("-ar"))
    }

    // MARK: Video bit rates

    func testVideoBitRateLadder() {
        func rate(_ codec: String, _ target: ConversionPlan.VideoCodec, size: (Int, Int) = (1920, 1080), fps: Double = 24,
                  pix: String = "yuv420p", source: Int? = nil, hdr: Bool = false) -> Int {
            var s = video(0, codec, pix: pix, size: size, fps: fps, bitRate: source)
            if hdr { s.colorTransfer = "smpte2084" }
            return MediaPlanner.videoBitRate(for: s, codec: target, containerBitRate: nil)
        }
        // Floors asked for: 1080p SDR at least 8 Mbit/s as H.264, 6 as HEVC.
        XCTAssertGreaterThanOrEqual(rate("mpeg2video", .h264), 8_000_000)
        XCTAssertGreaterThanOrEqual(rate("mpeg2video", .hevc), 6_000_000)
        XCTAssertGreaterThanOrEqual(rate("mpeg2video", .h264, size: (1920, 800)), 8_000_000, "scope films are still 1080p-class")
        // More for 4K, 10-bit, HDR and high frame rates.
        XCTAssertGreaterThan(rate("vp9", .hevc, size: (3840, 2160)), 20_000_000)
        XCTAssertGreaterThan(rate("vp9", .hevc, size: (3840, 2160), pix: "yuv420p10le", hdr: true), rate("vp9", .hevc, size: (3840, 2160)))
        XCTAssertGreaterThan(rate("vp9", .hevc, pix: "yuv420p10le"), rate("vp9", .hevc))
        XCTAssertGreaterThan(rate("vp9", .h264, fps: 60), rate("vp9", .h264, fps: 30))
        // Never below the source, with headroom when the source's codec is more efficient.
        XCTAssertGreaterThanOrEqual(rate("mpeg4", .h264, source: 14_000_000), 14_000_000)
        XCTAssertGreaterThanOrEqual(rate("av1", .h264, source: 9_000_000), 14_000_000)
        XCTAssertGreaterThanOrEqual(rate("h264", .hevc, pix: "yuv420p10le", source: 12_000_000), 12_000_000)
        // A low-rate source does not drag the result below the ladder.
        XCTAssertGreaterThanOrEqual(rate("av1", .h264, source: 1_500_000), 8_000_000)
        // An absurdly large source (editing formats) is not matched.
        XCTAssertLessThanOrEqual(rate("prores", .h264, source: 180_000_000), 40_000_000)
        XCTAssertLessThanOrEqual(rate("prores", .hevc, size: (7680, 4320), fps: 60, pix: "yuv422p10le", source: 900_000_000), 80_000_000)
    }

    func testReencodedVideoKeepsColourTags() throws {
        var hdr = video(0, "vp9", pix: "yuv420p10le", size: (3840, 2160))
        hdr.colorTransfer = "smpte2084"
        hdr.colorPrimaries = "bt2020"
        hdr.colorSpace = "bt2020nc"
        hdr.colorRange = "tv"
        let args = try MediaPlanner.plan(probe("matroska,webm", [hdr])).ffmpegArguments(input: "a.mkv", output: "b.mp4")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "-color_trc")) + 1], "smpte2084")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "-color_primaries")) + 1], "bt2020")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "-colorspace")) + 1], "bt2020nc")
        XCTAssertTrue(args.contains("main10") && args.contains("p010le"))
        var plain = video(0, "vp9")
        plain.colorSpace = "unknown"
        XCTAssertFalse(try MediaPlanner.plan(probe("matroska,webm", [plain])).ffmpegArguments(input: "a.mkv", output: "b.mp4").contains("-colorspace"))
    }

    // MARK: Damaged timestamps

    func testTimestampRepairPlan() throws {
        var bframes = video(0, "hevc", pix: "yuv420p10le")
        bframes.hasBFrames = 2
        var plan = try MediaPlanner.plan(probe("mov,mp4,m4a,3gp,3g2,mj2", [bframes, audio(1, "aac", channels: 6)]))
        XCTAssertTrue(plan.wantsTimestampCheck)
        XCTAssertFalse(plan.needsConversion, "a healthy file is shared as it is")
        plan.repairVideoTimestamps = true
        plan.timestampTail = [.init(decodeTime: 955_955, presentationTime: 958_958)]
        XCTAssertEqual(plan.ffmpegArguments(input: "a.mp4", output: "b.mp4").first { $0.hasPrefix("dts2pts") }, "dts2pts",
                       "without the first sample's decode time the tail cannot be addressed")
        plan.timestampBase = -2002
        let args = plan.ffmpegArguments(input: "a.mp4", output: "b.mp4")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "-bsf:v")) + 1],
                       "dts2pts,setts=pts=if(eq(DTS-STARTDTS\\,957957)\\,STARTDTS+(960960)\\,PTS)")
        XCTAssertTrue(plan.isRemuxOnly, "repairing copies the streams")
        let fallback = try XCTUnwrap(plan.fallbackPlan)
        XCTAssertTrue(fallback.reencodesVideo)
        XCTAssertFalse(fallback.repairVideoTimestamps)
        XCTAssertFalse(fallback.ffmpegArguments(input: "a.mp4", output: "b.mp4").contains("-bsf:v"))

        var noB = video(0, "h264")
        noB.hasBFrames = 0
        XCTAssertFalse(try MediaPlanner.plan(probe("mov,mp4,m4a,3gp,3g2,mj2", [noB])).wantsTimestampCheck)
        XCTAssertFalse(try MediaPlanner.plan(probe("matroska,webm", [video(0, "vp9")])).wantsTimestampCheck, "re-encoded video gets new timestamps anyway")
    }

    func testTimestampReports() {
        // Healthy: the decoder's output order has rising presentation times.
        let healthy = (0..<120).map { String($0 * 1001) }.joined(separator: "\n")
        XCTAssertFalse(TimestampReport.parse(ffprobeFrameTimes: healthy).isDamaged)
        // pts == dts with B-frames: display order I B B P reads 0 2 3 1 ...
        let damaged = (0..<30).flatMap { g in [0, 2, 3, 1].map { String((g * 4 + $0) * 1001) } }.joined(separator: "\n")
        let report = TimestampReport.parse(ffprobeFrameTimes: damaged + "\nN/A\n")
        XCTAssertEqual(report.frames, 120)
        XCTAssertEqual(report.backwardSteps, 30)
        XCTAssertTrue(report.isDamaged)
        // One odd frame (a broken spot in an otherwise good file) is not "damaged".
        XCTAssertFalse(TimestampReport.parse(ffprobeFrameTimes: healthy + "\n5").isDamaged)

        let sane = PacketTimesReport.parse(ffprobePacketTimes: "0,-2002\n4004,-1001\n2002,0\n1001,1001\n3003,2002\n")
        XCTAssertTrue(sane.isSane)
        XCTAssertEqual(sane.largestReorder, 5, accuracy: 0.01)
        XCTAssertFalse(PacketTimesReport.parse(ffprobePacketTimes: "0,0\n1001,1001\n1001,2002\n").isSane, "presentation before decode, duplicate")
    }

    func testTimestampTail() {
        // The end of an H.264 clip: decode order ... 508928 509440 509952 510464, displayed 508928 509440 510464 509952
        // (the last two swap), reorder delay 2 frames of 512.
        let corrections = TimestampTail.corrections(outputOrder: [507_904, 508_416, 508_928, 509_440, 510_464, 509_952], delayFrames: 2, count: 3)
        let expected: [TimestampTail.Correction] = [
            TimestampTail.Correction(decodeTime: 509_440, presentationTime: 510_464),
            TimestampTail.Correction(decodeTime: 509_952, presentationTime: 511_488),
            TimestampTail.Correction(decodeTime: 510_464, presentationTime: 510_976),
        ]
        XCTAssertEqual(corrections, expected)
        XCTAssertEqual(Set(corrections.map(\.presentationTime)).count, 3)
        XCTAssertTrue(TimestampTail.corrections(outputOrder: [1, 1, 2], delayFrames: 0, count: 2).isEmpty, "ambiguous input is left alone")
        XCTAssertEqual(TimestampTail.bitstreamFilter(tail: []), "dts2pts")
    }

    // MARK: Stream selection

    func testPicksDefaultAudioAndFirstTextSubtitleAndSkipsCoverArt() throws {
        var cover = video(0, "mjpeg", pix: "yuvj420p", size: (600, 600))
        cover.isAttachedPicture = true
        let plan = try MediaPlanner.plan(probe("matroska,webm", [
            cover, video(1, "h264"), audio(2, "aac"), audio(3, "ac3", isDefault: true),
            subtitle(4, "hdmv_pgs_subtitle"), subtitle(5, "subrip"), subtitle(6, "ass"),
        ]), sidecarSubtitles: "/x/Film.srt")
        XCTAssertEqual(plan.video?.stream, 1)
        XCTAssertEqual(plan.audio?.stream, 3)
        XCTAssertEqual(plan.subtitles, .embedded(stream: 5), "embedded text wins over a sidecar; picture subtitles are skipped")
        let args = plan.ffmpegArguments(input: "a.mkv", output: "b.mp4")
        XCTAssertEqual(args.filter { $0 == "-map" }.count, 3)
        XCTAssertTrue(args.contains("0:5"))
        XCTAssertEqual(args.last, "b.mp4")
    }

    func testAudioOnlyAndNothing() throws {
        let plan = try MediaPlanner.plan(probe("ogg", [audio(0, "vorbis")]))
        XCTAssertNil(plan.video)
        XCTAssertNotNil(plan.audio)
        XCTAssertThrowsError(try MediaPlanner.plan(probe("matroska,webm", [subtitle(0, "subrip")])))
    }

    // MARK: Parsing

    func testParsesFFprobeJSON() throws {
        let json = """
        {"streams":[
          {"index":0,"codec_name":"hevc","profile":"Main 10","codec_type":"video","width":1920,"height":1080,
           "pix_fmt":"yuv420p10le","field_order":"progressive","r_frame_rate":"24000/1001","avg_frame_rate":"24000/1001",
           "color_transfer":"bt709","disposition":{"default":1,"attached_pic":0},"tags":{"BPS":"8000000","language":"eng"}},
          {"index":1,"codec_name":"ac3","codec_type":"audio","channels":6,"sample_rate":"48000","bit_rate":"448000",
           "disposition":{"default":1,"attached_pic":0},"tags":{"language":"eng","title":"Surround"}},
          {"index":2,"codec_name":"subrip","codec_type":"subtitle","disposition":{"default":0}},
          {"index":3,"codec_name":"ttf","codec_type":"attachment"}
        ],"format":{"format_name":"matroska,webm","duration":"5400.250000","bit_rate":"9000000"}}
        """
        let p = try ProbeResult.parse(ffprobeJSON: Data(json.utf8))
        XCTAssertEqual(p.formatName, "matroska,webm")
        XCTAssertEqual(p.duration, 5400.25, accuracy: 0.001)
        XCTAssertEqual(p.streams.count, 4)
        XCTAssertEqual(p.streams[0].codec, "hevc")
        XCTAssertEqual(p.streams[0].bitDepth, 10)
        XCTAssertEqual(p.streams[0].frameRate ?? 0, 23.976, accuracy: 0.001)
        XCTAssertEqual(p.streams[0].bitRate, 8_000_000)
        XCTAssertTrue(p.streams[0].isDefault)
        XCTAssertEqual(p.streams[1].channels, 6)
        XCTAssertEqual(p.streams[1].title, "Surround")
        XCTAssertEqual(p.streams[2].kind, .subtitle)
        XCTAssertEqual(p.streams[3].kind, .other)
        XCTAssertFalse(p.isMP4Family)
        XCTAssertThrowsError(try ProbeResult.parse(ffprobeJSON: Data("nope".utf8)))
    }

    func testProgressParsing() {
        var progress = FFmpegProgress()
        XCTAssertFalse(progress.consume(line: "frame=100"))
        XCTAssertFalse(progress.consume(line: "out_time_us=30000000"))
        XCTAssertFalse(progress.consume(line: "speed=12.5x"))
        XCTAssertTrue(progress.consume(line: "progress=continue"))
        XCTAssertEqual(progress.fraction(duration: 120), 0.25, accuracy: 1e-9)
        XCTAssertEqual(progress.speed, 12.5)
        progress.consume(line: "out_time_us=N/A")
        XCTAssertEqual(progress.outTime, 30)
        progress.consume(line: "out_time_us=200000000")
        XCTAssertEqual(progress.fraction(duration: 120), 0.999, "never claims 100% before the end")
        XCTAssertTrue(progress.consume(line: "progress=end"))
        XCTAssertEqual(progress.fraction(duration: 120), 1)
    }

    func testPreparingMessageRoundTrips() {
        let message = ControlMessage.preparing(fraction: 0.43)
        XCTAssertEqual(ControlMessage.decode(message.encoded()), message)
    }
}
