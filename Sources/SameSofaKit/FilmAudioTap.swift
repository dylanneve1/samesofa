import AVFoundation
import CAudioTap
import MediaToolbox
import SameSofaCore

/// Listens to the film's decoded sound inside AVPlayer (MTAudioProcessingTap)
/// without changing it: the player goes on to play exactly what it decoded
/// through the normal sound output. The copy taken here, folded down to
/// stereo and stamped with its position in the film, is the echo canceller's
/// reference for "what the speakers are playing".
final class FilmAudioTap {
    private final class Context {
        weak var hub: AudioHub?
        let ring: TimedRing
        /// Left/right share of each source channel, from the track's channel layout.
        let layoutGains: [StereoGain]?
        var gains: [StereoGain] = []
        var channels = 2
        var nonInterleaved = true
        var isFloat = true
        var sampleRate = 48_000.0
        /// Test hook: receives every buffer exactly as the player will play it.
        let monitor: FilmAudioTap.Monitor?
        init(hub: AudioHub, layoutGains: [StereoGain]?, monitor: FilmAudioTap.Monitor?) {
            self.hub = hub
            ring = hub.filmReference
            self.layoutGains = layoutGains
            self.monitor = monitor
        }
    }

    static let labelOffsetFrames: Int64 = 48

    /// Called on the player's audio thread with (buffers, frames, channels, position in frames or nil).
    typealias Monitor = (UnsafeMutableAudioBufferListPointer, Int, Int, Int64?) -> Void

    /// Builds an audio mix whose only job is to let `hub` listen to `track`.
    /// `roles`: what each channel is, in track order (nil if unknown).
    static func audioMix(for track: AVAssetTrack, roles: [ChannelRole]?, hub: AudioHub, monitor: Monitor? = nil) -> AVAudioMix? {
        let context = Context(hub: hub, layoutGains: roles.map(Downmix.stereoGains(for:)), monitor: monitor)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let asbd = format.pointee
                context.channels = Int(asbd.mChannelsPerFrame)
                context.nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
                context.isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
                context.sampleRate = asbd.mSampleRate
                if let layout = context.layoutGains, layout.count == context.channels {
                    context.gains = layout
                } else {
                    context.gains = Downmix.stereoGains(for: Downmix.assumedRoles(channelCount: context.channels))
                }
                context.ring.clear()
                context.hub?.filmFormatChanged(sampleRate: asbd.mSampleRate)
            },
            unprepare: { tap in
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.ring.clear()
            },
            process: { tap, frameCount, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, &range, framesOut)
                guard status == noErr else { return }
                // From here on the buffers are only read: what the player plays is what it decoded.
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let frames = Int(framesOut.pointee)
                guard context.isFloat, frames > 0 else { return }
                // The player labels each buffer with the time of the one before
                // it (measured on every format tried: the sound in a buffer is
                // exactly one buffer plus 48 samples later in the film than its
                // label says). The true position is what matters for lining
                // the echo reference up with the film's clock.
                let start = range.start.seconds
                let position: Int64? = range.start.isNumeric && start.isFinite
                    ? Int64((start * context.sampleRate).rounded()) + Int64(frames) + FilmAudioTap.labelOffsetFrames : nil
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                FilmAudioTap.copy(buffers: buffers, frames: frames, position: position, context: context)
                context.monitor?(buffers, frames, context.channels, position)
            }
        )
        guard let tap = SSAudioTapCreate(&callbacks) else {
            Unmanaged<Context>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    /// Folds the film's channels down to stereo and stores them for the echo canceller.
    private static func copy(buffers: UnsafeMutableAudioBufferListPointer, frames: Int, position: Int64?, context: Context) {
        let channels = context.channels
        let gains = context.gains
        var peak: Float = 0
        context.ring.append(frames: frames, position: position) { destination, offset, count in
            memset(destination, 0, count * 2 * MemoryLayout<Float>.size)
            for channel in 0..<min(channels, gains.count) {
                let gain = gains[channel]
                guard gain.left != 0 || gain.right != 0 else { continue }
                let source: UnsafePointer<Float>
                let stride: Int
                if context.nonInterleaved {
                    guard channel < buffers.count, let data = buffers[channel].mData else { continue }
                    source = UnsafePointer(data.assumingMemoryBound(to: Float.self)) + offset
                    stride = 1
                } else {
                    guard let data = buffers[0].mData else { continue }
                    source = UnsafePointer(data.assumingMemoryBound(to: Float.self)) + offset * channels + channel
                    stride = channels
                }
                for i in 0..<count {
                    let sample = source[i * stride]
                    destination[i * 2] += sample * gain.left
                    destination[i * 2 + 1] += sample * gain.right
                }
            }
            for i in 0..<(count * 2) { peak = max(peak, abs(destination[i])) }
        }
        if let hub = context.hub { hub.filmLevel = max(peak, hub.filmLevel * 0.9) }
    }
}

/// For tests that render the film's sound path offline.
public enum FilmListening {
    /// The audio mix SameSofa attaches to a film's sound track while it plays.
    public static func audioMix(for track: AVAssetTrack, hub: AudioHub, monitor: FilmAudioMonitor? = nil) async -> AVAudioMix? {
        var roles: [ChannelRole]?
        if let format = (try? await track.load(.formatDescriptions))?.first {
            roles = ChannelLayoutReader.roles(for: format)
        }
        return FilmAudioTap.audioMix(for: track, roles: roles, hub: hub, monitor: monitor)
    }
}
