import AVFoundation

/// What is actually being played, in words, for the "Playback quality" readout.
public struct PlaybackQuality: Equatable, Sendable {
    /// e.g. "HEVC 10-bit · 1920 × 800 · 23.98 fps · 2.0 Mbit/s"
    public var video: String?
    /// e.g. "AAC · 5.1 · 48 kHz · 224 kbit/s"
    public var audio: String?

    public init(video: String? = nil, audio: String? = nil) {
        self.video = video
        self.audio = audio
    }

    static func describe(video: AVAssetTrack?, audio: AVAssetTrack?) async -> PlaybackQuality {
        var quality = PlaybackQuality()
        if let video, let format = (try? await video.load(.formatDescriptions))?.first {
            let rate = (try? await video.load(.estimatedDataRate)) ?? 0
            let fps = (try? await video.load(.nominalFrameRate)) ?? 0
            quality.video = describeVideo(format, bitRate: Double(rate), frameRate: Double(fps))
        }
        if let audio, let format = (try? await audio.load(.formatDescriptions))?.first {
            let rate = (try? await audio.load(.estimatedDataRate)) ?? 0
            quality.audio = describeAudio(format, bitRate: Double(rate))
        }
        return quality
    }

    static func fourCharacters(_ code: FourCharCode) -> String {
        let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return (String(bytes: bytes, encoding: .ascii) ?? "?").trimmingCharacters(in: .whitespaces)
    }

    static func bitRateText(_ bitsPerSecond: Double) -> String? {
        guard bitsPerSecond.isFinite, bitsPerSecond > 0 else { return nil }
        return bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mbit/s", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kbit/s", bitsPerSecond / 1000)
    }

    static func describeVideo(_ format: CMFormatDescription, bitRate: Double, frameRate: Double) -> String {
        let code = fourCharacters(CMFormatDescriptionGetMediaSubType(format))
        var codec: String
        switch code {
        case "avc1", "avc3": codec = "H.264"
        case "hvc1", "hev1": codec = "HEVC"
        case "dvh1", "dvhe": codec = "HEVC (Dolby Vision)"
        case "av01": codec = "AV1"
        case "vp09": codec = "VP9"
        case "mp4v": codec = "MPEG-4"
        default: codec = code
        }
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        if let depth = extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int, depth > 8 {
            codec += " \(depth)-bit"
        }
        if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String {
            if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String { codec += " HDR (PQ)" }
            if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String { codec += " HDR (HLG)" }
        }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        var parts = [codec, "\(size.width) × \(size.height)"]
        if frameRate > 0 { parts.append(String(format: "%.2f fps", frameRate).replacingOccurrences(of: ".00 fps", with: " fps")) }
        if let rate = bitRateText(bitRate) { parts.append(rate) }
        return parts.joined(separator: " · ")
    }

    static func describeAudio(_ format: CMFormatDescription, bitRate: Double) -> String {
        let code = fourCharacters(CMFormatDescriptionGetMediaSubType(format))
        let codec: String
        switch code.lowercased() {
        case "aac", "mp4a": codec = "AAC"
        case "aach", "aacp": codec = "HE-AAC"
        case "ac-3": codec = "Dolby Digital (AC-3)"
        case "ec-3": codec = "Dolby Digital Plus (E-AC-3)"
        case "alac": codec = "Apple Lossless"
        case "flac": codec = "FLAC"
        case "opus": codec = "Opus"
        case "lpcm": codec = "PCM"
        default: codec = code
        }
        var parts = [codec]
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            switch asbd.mChannelsPerFrame {
            case 1: parts.append("mono")
            case 2: parts.append("stereo")
            case 6: parts.append("5.1")
            case 8: parts.append("7.1")
            default: parts.append("\(asbd.mChannelsPerFrame) channels")
            }
            if asbd.mSampleRate > 0 {
                let kHz = asbd.mSampleRate / 1000
                parts.append(kHz == kHz.rounded() ? String(format: "%.0f kHz", kHz) : String(format: "%.1f kHz", kHz))
            }
        }
        if let rate = bitRateText(bitRate) { parts.append(rate) }
        return parts.joined(separator: " · ")
    }
}
