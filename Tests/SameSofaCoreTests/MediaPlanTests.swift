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
        XCTAssertEqual(bitRate, 2_000_000, "small films get the 2 Mbit/s floor")
        XCTAssertEqual(gop, 50)
        XCTAssertFalse(deinterlace)
        XCTAssertEqual(plan.audio?.action, .encode(channels: 2, bitRate: 192_000), "AVPlayer won't play MP3 inside MP4")
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
        XCTAssertEqual(bitRate, Int(1280.0 * 720 * 30 * 0.14))
        XCTAssertEqual(plan.audio?.action, .encode(channels: 2, bitRate: 192_000))
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
        XCTAssertEqual(plan.audio?.action, .encode(channels: 2, bitRate: 192_000))
    }

    func testAudioDecisions() {
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "aac")), .copy)
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "ac3", channels: 6)), .copy)
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "alac")), .copy)
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "dts", channels: 6)), .encode(channels: 6, bitRate: 384_000))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "truehd", channels: 8)), .encode(channels: 6, bitRate: 384_000))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "vorbis", channels: 1)), .encode(channels: 1, bitRate: 96_000))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "flac")), .encode(channels: 2, bitRate: 192_000))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "mp3")), .encode(channels: 2, bitRate: 192_000))
        XCTAssertEqual(MediaPlanner.audioAction(audio(0, "pcm_s16le")), .encode(channels: 2, bitRate: 192_000))
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
