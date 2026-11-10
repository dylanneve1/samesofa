import Foundation

// Decisions about the sound path that need no audio hardware: is the output
// a pair of headphones, should the film be cancelled from the microphone,
// how a surround track folds down to the two-channel echo reference, and how
// the reference is kept in step with what the speakers are playing.

/// What the film's sound comes out of.
public enum OutputKind: String, Sendable {
    /// Loudspeakers: the microphone hears the film.
    case speakers
    /// Headphones, AirPods, a headset: the microphone doesn't.
    case headphones
}

/// The current sound output, as Core Audio describes it.
public struct OutputRoute: Equatable, Sendable {
    public enum Transport: String, Sendable {
        case builtIn, bluetooth, usb, hdmi, displayPort, airPlay, thunderbolt, virtual, aggregate, other
    }

    public var name: String
    public var transport: Transport
    /// Core Audio data source code of a built-in output, e.g. "hdpn" (headphone jack) or "ispk".
    public var dataSource: String?
    /// The same device also has a microphone (a headset rather than a pair of speakers).
    public var hasInput: Bool

    public init(name: String, transport: Transport, dataSource: String? = nil, hasInput: Bool = false) {
        self.name = name
        self.transport = transport
        self.dataSource = dataSource
        self.hasInput = hasInput
    }

    public static let unknown = OutputRoute(name: "Unknown output", transport: .other)

    static let headphoneWords = ["headphone", "headset", "earphone", "earbud", "airpods", "buds"]
    static let speakerWords = ["speaker", "display", "monitor", "soundbar", "homepod"]

    public var kind: OutputKind {
        let lower = name.lowercased()
        let saysHeadphones = Self.headphoneWords.contains { lower.contains($0) }
        let saysSpeakers = Self.speakerWords.contains { lower.contains($0) }
        switch transport {
        case .builtIn:
            return dataSource == "hdpn" || saysHeadphones ? .headphones : .speakers
        case .bluetooth:
            // Mostly AirPods and headsets; Bluetooth speakers usually say so.
            return saysSpeakers && !saysHeadphones ? .speakers : .headphones
        case .usb:
            // USB headsets have a microphone; DACs, docks and display speakers don't.
            if saysHeadphones { return .headphones }
            if saysSpeakers { return .speakers }
            return hasInput ? .headphones : .speakers
        default:
            return saysHeadphones ? .headphones : .speakers
        }
    }
}

/// The "Sound output" setting.
public enum EchoSetting: String, CaseIterable, Sendable {
    /// Cancel the film from the microphone unless headphones are detected.
    case automatic
    /// Always cancel (the output is loudspeakers, whatever it is called).
    case speakers
    /// Never cancel the film (headphones).
    case headphones

    /// Should the film's sound be removed from the microphone?
    public func cancelsFilmEcho(on route: OutputRoute) -> Bool {
        switch self {
        case .automatic: return route.kind == .speakers
        case .speakers: return true
        case .headphones: return false
        }
    }
}

/// Where one channel of a film's sound track sits in the room.
public enum ChannelRole: Sendable {
    case left, right, centre, lfe, leftSurround, rightSurround, centreSurround, mono, other
}

/// How much of one source channel goes to the left and right of a stereo fold-down.
public struct StereoGain: Equatable, Sendable {
    public var left: Float
    public var right: Float
    public init(left: Float, right: Float) {
        self.left = left
        self.right = right
    }
}

public enum Downmix {
    /// ITU-R BS.775 fold-down: centre and surrounds at -3 dB, no LFE.
    /// Used for the echo reference and the level meter; the audible downmix
    /// is done by the system's audio output.
    public static func stereoGains(for roles: [ChannelRole]) -> [StereoGain] {
        let half: Float = 0.70710678
        return roles.map { role in
            switch role {
            case .left: return StereoGain(left: 1, right: 0)
            case .right: return StereoGain(left: 0, right: 1)
            case .centre, .mono: return StereoGain(left: half, right: half)
            case .leftSurround: return StereoGain(left: half, right: 0)
            case .rightSurround: return StereoGain(left: 0, right: half)
            case .centreSurround: return StereoGain(left: 0.5, right: 0.5)
            case .lfe, .other: return StereoGain(left: 0, right: 0)
            }
        }
    }

    /// Fallback when the track does not say what its channels are.
    public static func assumedRoles(channelCount: Int) -> [ChannelRole] {
        switch channelCount {
        case 1: return [.mono]
        case 2: return [.left, .right]
        default: return [.left, .right] + Array(repeating: .other, count: max(0, channelCount - 2))
        }
    }
}

/// Keeps a reader in step with a timeline it does not own.
///
/// The echo reference has to be the sound the speakers are playing at the
/// moment the microphone block was recorded. The film's position comes from
/// the player's clock and the voice's from the output device's clock, while
/// blocks are counted on the microphone's clock; the three never agree
/// exactly. The cursor reads contiguously, bends its speed by a fraction of a
/// percent to stay on target, and jumps only when it is far off (seek, pause,
/// device change).
public struct ReferenceCursor: Sendable {
    public private(set) var position: Double?
    /// Samples per second of the timeline being read.
    public var sampleRate: Double
    /// Further off than this (seconds): jump instead of bending.
    public var jumpThreshold = 0.005
    /// Largest speed correction.
    public var maxBend = 0.003

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    public mutating func reset() { position = nil }

    /// `desired`: where the timeline says the block should start (samples).
    /// `step`: timeline samples per output sample at nominal speed.
    /// Returns where to start reading and the step to use for `frames` samples.
    public mutating func next(desired: Double, step: Double, frames: Int) -> (start: Double, step: Double) {
        guard let current = position, abs(current - desired) <= jumpThreshold * sampleRate else {
            position = desired + step * Double(frames)
            return (desired, step)
        }
        // Close the gap over about a second.
        let bend = min(maxBend, max(-maxBend, (desired - current) / sampleRate))
        let adjusted = step * (1 + bend)
        position = current + adjusted * Double(frames)
        return (current, adjusted)
    }
}
