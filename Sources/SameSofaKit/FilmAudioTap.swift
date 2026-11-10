import AVFoundation
import CAudioTap
import MediaToolbox

/// Pulls the film's decoded audio out of AVPlayer (MTAudioProcessingTap),
/// hands it to the AudioHub so it plays through the same engine as the call,
/// and silences AVPlayer's own output.
final class FilmAudioTap {
    private final class Context {
        let ring: StereoRing
        weak var hub: AudioHub?
        var channels = 2
        var nonInterleaved = true
        var isFloat = true
        var writeOffset = 0
        init(ring: StereoRing, hub: AudioHub) { self.ring = ring; self.hub = hub }
    }

    /// Builds an audio mix that routes `track` through `hub`.
    static func audioMix(for track: AVAssetTrack, hub: AudioHub) -> AVAudioMix? {
        let context = Context(ring: hub.filmRing, hub: hub)
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
                context.ring.clear()
                context.hub?.filmFormatChanged(sampleRate: asbd.mSampleRate)
            },
            unprepare: { tap in
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.ring.clear()
            },
            process: { tap, frameCount, _, bufferList, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil, framesOut)
                guard status == noErr else { return }
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let frames = Int(framesOut.pointee)
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                if context.isFloat, frames > 0 {
                    FilmAudioTap.copy(buffers: buffers, frames: frames, context: context)
                }
                // AVPlayer's own output goes silent; the AudioHub plays the film instead.
                for buffer in buffers {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
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

    /// Downmixes whatever the film has to stereo and writes it into the ring.
    private static func copy(buffers: UnsafeMutableAudioBufferListPointer, frames: Int, context: Context) {
        let channels = context.channels
        func sample(_ channel: Int, _ frame: Int) -> Float {
            if context.nonInterleaved {
                guard channel < buffers.count, let data = buffers[channel].mData else { return 0 }
                return data.assumingMemoryBound(to: Float.self)[frame]
            }
            guard let data = buffers[0].mData else { return 0 }
            return data.assumingMemoryBound(to: Float.self)[frame * channels + channel]
        }
        context.ring.write(frames: frames) { dst, count in
            // `write` may call us in two runs when it wraps; track the offset.
            let base = context.writeOffset
            for i in 0..<count {
                let f = base + i
                var l: Float, r: Float
                switch channels {
                case 1:
                    l = sample(0, f); r = l
                case 6:
                    // L R C LFE Ls Rs -> stereo, keeping dialogue (centre) audible.
                    let c = sample(2, f) * 0.707
                    l = sample(0, f) + c + sample(4, f) * 0.707
                    r = sample(1, f) + c + sample(5, f) * 0.707
                    l *= 0.6; r *= 0.6
                default:
                    l = sample(0, f); r = sample(1, f)
                }
                dst[i * 2] = l
                dst[i * 2 + 1] = r
            }
            context.writeOffset += count
        }
        context.writeOffset = 0
    }
}
