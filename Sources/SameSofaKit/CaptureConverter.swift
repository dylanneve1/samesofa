import AudioToolbox
import AVFoundation

/// Turns whatever a microphone delivers (any sample rate, any number of
/// channels) into 48 kHz mono Float32 for the echo canceller.
///
/// Made for the audio thread: everything is allocated when it is created,
/// and converting uses the C AudioConverter only (no Objective-C objects, no
/// allocation, no locks).
///
/// Several channels are averaged. A laptop's microphone array has a capsule
/// on every channel; an audio interface often has the microphone on one
/// input only, and not always the first: the average always contains it.
final class CaptureConverter {
    static let outputRate = 48_000.0
    /// The input proc's answer when it has handed over everything it had.
    private static let noMoreInput: OSStatus = 0x6e6f6d72 // 'nomr'

    struct Unsupported: Error, CustomStringConvertible {
        let description: String
    }

    let inputRate: Double
    let channels: Int
    private let interleaved: Bool
    private let maxInputFrames: Int
    private let outputCapacity: Int
    private let folded: UnsafeMutablePointer<Float>
    private let output: UnsafeMutablePointer<Float>
    private var converter: AudioConverterRef?
    /// What the converter may still take from `folded` in the current call.
    private let feed: UnsafeMutablePointer<Feed>

    private struct Feed {
        var data: UnsafeMutablePointer<Float>
        var frames: Int
    }

    /// `format`: what the microphone delivers. Float32 only (which is what
    /// AVAudioEngine's input always is), interleaved or not.
    init(format: AudioStreamBasicDescription, maxInputFrames: Int = 16_384) throws {
        let isFloat = format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32 && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
        guard isFloat else { throw Unsupported(description: "sample format not supported") }
        guard format.mSampleRate >= 8000, format.mSampleRate <= 384_000 else {
            throw Unsupported(description: "sample rate \(Int(format.mSampleRate)) Hz not supported")
        }
        guard format.mChannelsPerFrame >= 1, format.mChannelsPerFrame <= 64 else {
            throw Unsupported(description: "\(format.mChannelsPerFrame) channels not supported")
        }
        inputRate = format.mSampleRate
        channels = Int(format.mChannelsPerFrame)
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        self.maxInputFrames = maxInputFrames
        outputCapacity = Int((Double(maxInputFrames) * Self.outputRate / inputRate).rounded(.up)) + 64
        folded = .allocate(capacity: maxInputFrames)
        folded.initialize(repeating: 0, count: maxInputFrames)
        output = .allocate(capacity: outputCapacity)
        output.initialize(repeating: 0, count: outputCapacity)
        feed = .allocate(capacity: 1)
        feed.initialize(to: Feed(data: folded, frames: 0))
        if inputRate != Self.outputRate {
            let flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian
            var from = AudioStreamBasicDescription(mSampleRate: inputRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                                   mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                                   mBitsPerChannel: 32, mReserved: 0)
            var to = from
            to.mSampleRate = Self.outputRate
            var reference: AudioConverterRef?
            let status = AudioConverterNew(&from, &to, &reference)
            guard status == noErr, let reference else {
                folded.deallocate(); output.deallocate(); feed.deallocate()
                throw Unsupported(description: "no converter from \(Int(inputRate)) Hz (\(status))")
            }
            converter = reference
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        folded.deallocate()
        output.deallocate()
        feed.deallocate()
    }

    /// Forgets what is still inside the sample rate converter.
    func reset() {
        if let converter { AudioConverterReset(converter) }
    }

    /// Converts `frames` frames from `buffers` and hands the result to `body`
    /// (48 kHz mono samples, count), possibly in several pieces. Buffers
    /// that do not hold what they claim are skipped.
    func convert(_ buffers: UnsafePointer<AudioBufferList>, frames: Int, _ body: (UnsafePointer<Float>, Int) -> Void) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        var offset = 0
        while offset < frames {
            let count = min(frames - offset, maxInputFrames)
            guard fold(list, offset: offset, frames: count) else { return }
            guard let converter else {
                body(folded, count)
                offset += count
                continue
            }
            feed.pointee = Feed(data: folded, frames: count)
            // Until the converter has taken all of it (it asks for input in pieces).
            var rounds = 0
            while feed.pointee.frames > 0, rounds < 8 {
                rounds += 1
                var produced = UInt32(outputCapacity)
                var out = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(outputCapacity * MemoryLayout<Float>.size), mData: UnsafeMutableRawPointer(output)))
                let status = AudioConverterFillComplexBuffer(converter, Self.supply, UnsafeMutableRawPointer(feed), &produced, &out, nil)
                if produced > 0 { body(output, Int(produced)) }
                if status != noErr, status != Self.noMoreInput { feed.pointee.frames = 0; break }
            }
            offset += count
        }
    }

    /// Averages the channels of `frames` frames starting at `offset` into `folded`.
    private func fold(_ list: UnsafeMutableAudioBufferListPointer, offset: Int, frames: Int) -> Bool {
        let size = MemoryLayout<Float>.size
        if interleaved {
            guard list.count >= 1, let data = list[0].mData, Int(list[0].mDataByteSize) >= (offset + frames) * channels * size else { return false }
            let source = data.assumingMemoryBound(to: Float.self) + offset * channels
            if channels == 1 {
                memcpy(folded, source, frames * size)
            } else {
                let scale = 1 / Float(channels)
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += source[i * channels + c] }
                    folded[i] = sum * scale
                }
            }
            return true
        }
        guard list.count >= channels else { return false }
        for c in 0..<channels {
            guard let data = list[c].mData, Int(list[c].mDataByteSize) >= (offset + frames) * size else { return false }
            let source = data.assumingMemoryBound(to: Float.self) + offset
            if c == 0 {
                memcpy(folded, source, frames * size)
            } else {
                for i in 0..<frames { folded[i] += source[i] }
            }
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for i in 0..<frames { folded[i] *= scale }
        }
        return true
    }

    private static let supply: AudioConverterComplexInputDataProc = { _, packets, data, _, context in
        guard let context else { packets.pointee = 0; return CaptureConverter.noMoreInput }
        let feed = context.assumingMemoryBound(to: Feed.self)
        guard feed.pointee.frames > 0 else {
            packets.pointee = 0
            return CaptureConverter.noMoreInput
        }
        let count = min(Int(packets.pointee), feed.pointee.frames)
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mNumberChannels = 1
        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(feed.pointee.data)
        data.pointee.mBuffers.mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
        packets.pointee = UInt32(count)
        feed.pointee.data += count
        feed.pointee.frames -= count
        return noErr
    }
}
