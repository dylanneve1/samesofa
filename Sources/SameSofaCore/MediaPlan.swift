import Foundation

// Deciding how to turn a film AVFoundation can't open (MKV, AVI, WebM, ...)
// into an MP4 it can, stream by stream: copy what macOS already decodes
// (fast and lossless), re-encode only what it doesn't. Pure logic, no
// processes: the ffmpeg/ffprobe helper is run by SameSofaKit.FilmPreparer.

/// One stream as reported by `ffprobe -show_streams -show_format -of json`.
public struct ProbedStream: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case video, audio, subtitle, other
    }

    public var index: Int
    public var kind: Kind
    /// FFmpeg codec name, e.g. "h264", "hevc", "mpeg4", "vp9", "aac", "dts", "subrip".
    public var codec: String
    public var profile: String?
    public var pixelFormat: String?
    public var bitsPerRawSample: Int?
    public var width: Int = 0
    public var height: Int = 0
    public var frameRate: Double?
    public var fieldOrder: String?
    public var colorTransfer: String?
    public var channels: Int = 0
    public var sampleRate: Int = 0
    public var bitRate: Int?
    public var isDefault = false
    /// Cover art in MKV/MP4/MP3 shows up as a one-frame "video" stream.
    public var isAttachedPicture = false
    public var language: String?
    public var title: String?

    public init(index: Int, kind: Kind, codec: String) {
        self.index = index
        self.kind = kind
        self.codec = codec
    }

    /// Bits per colour sample, from the pixel format when ffprobe doesn't say.
    public var bitDepth: Int {
        if let bits = bitsPerRawSample, bits > 0 { return bits }
        guard let pix = pixelFormat else { return 8 }
        for depth in [16, 14, 12, 10, 9] where pix.contains("p\(depth)") { return depth }
        return 8
    }

    public var isHDR: Bool { ["smpte2084", "arib-std-b67"].contains(colorTransfer ?? "") }

    public var isInterlaced: Bool {
        guard let order = fieldOrder else { return false }
        return !["progressive", "unknown", ""].contains(order)
    }
}

public struct ProbeResult: Equatable, Sendable {
    /// e.g. "matroska,webm", "avi", "mov,mp4,m4a,3gp,3g2,mj2".
    public var formatName: String
    public var duration: Double
    public var bitRate: Int?
    public var streams: [ProbedStream]

    public init(formatName: String, duration: Double, bitRate: Int? = nil, streams: [ProbedStream]) {
        self.formatName = formatName
        self.duration = duration
        self.bitRate = bitRate
        self.streams = streams
    }

    public var isMP4Family: Bool {
        formatName.split(separator: ",").contains { ["mov", "mp4", "m4a"].contains(String($0)) }
    }

    public var isAVI: Bool { formatName.split(separator: ",").contains("avi") }

    public enum ParseError: Error { case notJSON, noStreams }

    /// Parses ffprobe's JSON output.
    public static func parse(ffprobeJSON data: Data) throws -> ProbeResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        let format = root["format"] as? [String: Any] ?? [:]
        let rawStreams = root["streams"] as? [[String: Any]] ?? []
        guard !rawStreams.isEmpty else { throw ParseError.noStreams }
        func int(_ value: Any?) -> Int? {
            if let n = value as? Int { return n }
            if let n = value as? Double { return Int(n) }
            if let s = value as? String { return Int(s) ?? Double(s).map { Int($0) } }
            return nil
        }
        func double(_ value: Any?) -> Double? {
            if let n = value as? Double { return n }
            if let n = value as? Int { return Double(n) }
            if let s = value as? String { return Double(s) }
            return nil
        }
        func rate(_ value: Any?) -> Double? {
            guard let s = value as? String else { return nil }
            let parts = s.split(separator: "/")
            guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0, n > 0 else { return Double(s) }
            return n / d
        }
        var streams: [ProbedStream] = []
        for (position, raw) in rawStreams.enumerated() {
            let kind: ProbedStream.Kind
            switch raw["codec_type"] as? String {
            case "video": kind = .video
            case "audio": kind = .audio
            case "subtitle": kind = .subtitle
            default: kind = .other
            }
            var s = ProbedStream(index: int(raw["index"]) ?? position, kind: kind, codec: raw["codec_name"] as? String ?? "unknown")
            s.profile = raw["profile"] as? String
            s.pixelFormat = raw["pix_fmt"] as? String
            s.bitsPerRawSample = int(raw["bits_per_raw_sample"])
            s.width = int(raw["width"]) ?? 0
            s.height = int(raw["height"]) ?? 0
            // avg_frame_rate is the real rate for most files; r_frame_rate is a fallback.
            let avg = rate(raw["avg_frame_rate"]), real = rate(raw["r_frame_rate"])
            s.frameRate = [avg, real].compactMap { $0 }.first { $0 > 0 && $0 <= 240 }
            s.fieldOrder = raw["field_order"] as? String
            s.colorTransfer = raw["color_transfer"] as? String
            s.channels = int(raw["channels"]) ?? 0
            s.sampleRate = int(raw["sample_rate"]) ?? 0
            let tags = raw["tags"] as? [String: Any] ?? [:]
            // MKV files written by mkvmerge carry the bit rate as a "BPS" tag.
            s.bitRate = int(raw["bit_rate"]) ?? int(tags["BPS"]) ?? int(tags["BPS-eng"])
            let disposition = raw["disposition"] as? [String: Any] ?? [:]
            s.isDefault = int(disposition["default"]) == 1
            s.isAttachedPicture = int(disposition["attached_pic"]) == 1
            s.language = tags["language"] as? String
            s.title = tags["title"] as? String
            streams.append(s)
        }
        return ProbeResult(formatName: format["format_name"] as? String ?? "",
                           duration: double(format["duration"]) ?? 0,
                           bitRate: int(format["bit_rate"]),
                           streams: streams)
    }
}

/// What to do with the film before sharing it.
public struct ConversionPlan: Equatable, Sendable {
    public enum VideoCodec: String, Sendable { case h264, hevc }

    public enum VideoAction: Equatable, Sendable {
        /// Copy the compressed video as it is (`tagHvc1`: label HEVC the way AVFoundation wants).
        case copy(tagHvc1: Bool)
        /// Decode and re-encode with VideoToolbox (the Mac's hardware encoder).
        case encode(codec: VideoCodec, tenBit: Bool, bitRate: Int, keyframeInterval: Int, deinterlace: Bool)
    }

    public enum AudioAction: Equatable, Sendable {
        case copy
        /// Re-encode to AAC with this many channels.
        case encode(channels: Int, bitRate: Int)
    }

    public enum Subtitles: Equatable, Sendable {
        /// A text subtitle stream inside the film.
        case embedded(stream: Int)
        /// A separate .srt next to the film.
        case sidecar(path: String)
    }

    public struct Video: Equatable, Sendable {
        public var stream: Int
        public var action: VideoAction
    }

    public struct Audio: Equatable, Sendable {
        public var stream: Int
        public var action: AudioAction
    }

    public var video: Video?
    public var audio: Audio?
    public var subtitles: Subtitles?
    public var duration: Double
    /// False when the film is already an MP4/MOV that macOS plays as it is:
    /// then the original file is shared untouched.
    public var needsConversion: Bool
    /// Input needs regenerated timestamps (AVI).
    public var regenerateTimestamps = false
    /// One line per decision, for logs.
    public var notes: [String] = []

    public var reencodesVideo: Bool {
        if case .encode = video?.action { return true }
        return false
    }

    public var reencodesAudio: Bool {
        if case .encode = audio?.action { return true }
        return false
    }

    /// Only copies streams: takes seconds, no quality change.
    public var isRemuxOnly: Bool { !reencodesVideo && !reencodesAudio }

    /// Arguments for the ffmpeg helper (everything after the program name).
    /// Progress is written to stdout in `-progress` format.
    public func ffmpegArguments(input: String, output: String) -> [String] {
        var a = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats",
                 "-analyzeduration", "20000000", "-probesize", "50000000"]
        if regenerateTimestamps { a += ["-fflags", "+genpts"] }
        a += ["-i", input]
        var sidecarIndex: Int?
        if case .sidecar(let path) = subtitles {
            a += ["-i", path]
            sidecarIndex = 1
        }
        if let video { a += ["-map", "0:\(video.stream)"] }
        if let audio { a += ["-map", "0:\(audio.stream)"] }
        switch subtitles {
        case .embedded(let stream): a += ["-map", "0:\(stream)"]
        case .sidecar: a += ["-map", "\(sidecarIndex ?? 1):0"]
        case nil: break
        }
        a += ["-map_chapters", "-1", "-dn"]
        if let video {
            switch video.action {
            case .copy(let tagHvc1):
                a += ["-c:v", "copy"]
                if tagHvc1 { a += ["-tag:v", "hvc1"] }
            case .encode(let codec, let tenBit, let bitRate, let gop, let deinterlace):
                if deinterlace { a += ["-vf", "yadif=mode=send_frame:deint=interlaced"] }
                switch codec {
                case .h264:
                    a += ["-c:v", "h264_videotoolbox", "-profile:v", "high", "-pix_fmt", "yuv420p"]
                case .hevc:
                    a += ["-c:v", "hevc_videotoolbox", "-profile:v", tenBit ? "main10" : "main",
                          "-pix_fmt", tenBit ? "p010le" : "yuv420p", "-tag:v", "hvc1"]
                }
                a += ["-allow_sw", "1", "-b:v", String(bitRate), "-g", String(gop)]
            }
        }
        if let audio {
            switch audio.action {
            case .copy:
                a += ["-c:a", "copy"]
            case .encode(let channels, let bitRate):
                a += ["-c:a", "aac", "-ac", String(channels), "-b:a", String(bitRate)]
            }
        }
        if subtitles != nil {
            // Off until someone turns subtitles on in the app.
            a += ["-c:s", "mov_text", "-disposition:s:0", "0"]
        }
        a += ["-max_muxing_queue_size", "4096", "-f", "mp4", output]
        return a
    }
}

public enum MediaPlanner {
    public enum PlanError: Error, Equatable {
        /// Neither a video nor an audio stream.
        case nothingToPlay
    }

    /// Text subtitle codecs that can become an MP4 (mov_text) track.
    public static let textSubtitleCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"]

    /// Audio AVFoundation plays from an MP4. (MP3 is not among them: AVPlayer
    /// stays silent on MP3 inside MP4, so it is re-encoded like the rest.)
    public static let copyableAudio: Set<String> = ["aac", "ac3", "eac3", "alac"]

    /// Decides, stream by stream, what has to happen to `probe` for AVPlayer.
    /// `sidecarSubtitles` is the path of a same-named .srt next to the film.
    public static func plan(_ probe: ProbeResult, sidecarSubtitles: String? = nil) throws -> ConversionPlan {
        var notes: [String] = []
        let videos = probe.streams.filter { $0.kind == .video && !$0.isAttachedPicture }
        let audios = probe.streams.filter { $0.kind == .audio }
        let video = videos.first { $0.isDefault } ?? videos.first
        let audio = audios.first { $0.isDefault } ?? audios.first
        guard video != nil || audio != nil else { throw PlanError.nothingToPlay }

        var plan = ConversionPlan(duration: probe.duration, needsConversion: !probe.isMP4Family)
        plan.regenerateTimestamps = probe.isAVI

        if let video {
            let action = videoAction(video, containerBitRate: probe.bitRate)
            plan.video = .init(stream: video.index, action: action)
            switch action {
            case .copy: notes.append("video #\(video.index) \(video.codec): copy")
            case .encode(let codec, let tenBit, let bitRate, _, let deinterlace):
                notes.append("video #\(video.index) \(video.codec) \(video.pixelFormat ?? "?"): encode \(codec.rawValue)\(tenBit ? " 10-bit" : "") \(bitRate / 1000) kbit/s\(deinterlace ? " deinterlaced" : "")")
            }
        }
        if let audio {
            let action = audioAction(audio)
            plan.audio = .init(stream: audio.index, action: action)
            switch action {
            case .copy: notes.append("audio #\(audio.index) \(audio.codec): copy")
            case .encode(let channels, let bitRate): notes.append("audio #\(audio.index) \(audio.codec): encode aac \(channels) ch \(bitRate / 1000) kbit/s")
            }
        }
        if let text = probe.streams.first(where: { $0.kind == .subtitle && textSubtitleCodecs.contains($0.codec) }) {
            plan.subtitles = .embedded(stream: text.index)
            notes.append("subtitles #\(text.index) \(text.codec): mov_text")
        } else if let sidecarSubtitles {
            plan.subtitles = .sidecar(path: sidecarSubtitles)
            notes.append("subtitles from \((sidecarSubtitles as NSString).lastPathComponent): mov_text")
        }
        if !plan.isRemuxOnly { plan.needsConversion = true }
        if case .sidecar = plan.subtitles { plan.needsConversion = true }
        if case .embedded(let stream) = plan.subtitles, probe.isMP4Family,
           probe.streams.first(where: { $0.index == stream })?.codec != "mov_text" {
            plan.needsConversion = true
        }
        plan.notes = notes
        return plan
    }

    static func videoAction(_ s: ProbedStream, containerBitRate: Int?) -> ConversionPlan.VideoAction {
        let pix = s.pixelFormat ?? "yuv420p"
        let profile = (s.profile ?? "").lowercased()
        switch s.codec {
        case "h264":
            // VideoToolbox decodes 8-bit 4:2:0 H.264 only (not High 10 / 4:2:2 / 4:4:4).
            if ["yuv420p", "yuvj420p"].contains(pix), s.bitDepth == 8,
               !profile.contains("10"), !profile.contains("4:2:2"), !profile.contains("4:4:4") {
                return .copy(tagHvc1: false)
            }
        case "hevc":
            if ["yuv420p", "yuvj420p", "yuv420p10le"].contains(pix), s.bitDepth <= 10 {
                return .copy(tagHvc1: true)
            }
        default:
            break
        }
        return encoding(for: s, containerBitRate: containerBitRate)
    }

    static func encoding(for s: ProbedStream, containerBitRate: Int?) -> ConversionPlan.VideoAction {
        let width = max(s.width, 16), height = max(s.height, 16)
        let pixels = width * height
        let tenBit = s.bitDepth > 8 || s.isHDR
        // HEVC for 10-bit/HDR and anything above 1080p; H.264 otherwise (fastest, plays everywhere).
        let codec: ConversionPlan.VideoCodec = tenBit || pixels > 1920 * 1088 ? .hevc : .h264
        let fps = min(max(s.frameRate ?? 25, 1), 120)
        // Generous bits per pixel: hardware encoders need more than x264 for the same quality.
        let bitsPerPixel = codec == .hevc ? 0.09 : 0.14
        var bitRate = Int(Double(pixels) * fps * bitsPerPixel)
        // No point spending far more than the source did.
        if let source = s.bitRate ?? containerBitRate, source > 0 { bitRate = min(bitRate, source * 2) }
        bitRate = min(max(bitRate, 2_000_000), 60_000_000)
        let gop = max(Int((fps * 2).rounded()), 1)
        return .encode(codec: codec, tenBit: tenBit, bitRate: bitRate, keyframeInterval: gop, deinterlace: s.isInterlaced)
    }

    static func audioAction(_ s: ProbedStream) -> ConversionPlan.AudioAction {
        if copyableAudio.contains(s.codec), s.channels <= 8 { return .copy }
        let channels = min(max(s.channels, 1), 6)
        let bitRate = channels == 1 ? 96_000 : channels <= 2 ? 192_000 : 384_000
        return .encode(channels: channels, bitRate: bitRate)
    }
}

/// Reads ffmpeg's `-progress` output (key=value lines).
public struct FFmpegProgress: Equatable, Sendable {
    /// Seconds of output written so far.
    public private(set) var outTime: Double = 0
    /// Speed relative to real time ("12.3x"), when ffmpeg knows it.
    public private(set) var speed: Double?
    public private(set) var finished = false

    public init() {}

    /// Feeds one line. Returns true when a progress block ended (time to update the UI).
    @discardableResult
    public mutating func consume(line: String) -> Bool {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return false }
        switch parts[0] {
        case "out_time_us", "out_time_ms":
            // Both are microseconds (out_time_ms is misnamed in ffmpeg).
            if let us = Double(parts[1]), us >= 0 { outTime = us / 1_000_000 }
        case "speed":
            speed = Double(parts[1].replacingOccurrences(of: "x", with: ""))
        case "progress":
            if parts[1] == "end" { finished = true }
            return true
        default:
            break
        }
        return false
    }

    public func fraction(duration: Double) -> Double {
        if finished { return 1 }
        guard duration > 0 else { return 0 }
        return min(max(outTime / duration, 0), 0.999)
    }
}
