import AVFoundation
import CWebRTCAudioDevice
import WebRTC

/// Single-producer single-consumer ring of interleaved stereo Float32 samples.
/// The film's audio tap writes, the audio engine's render thread reads.
final class StereoRing {
    private var buffer: [Float]
    private let capacityFrames: Int
    private var writeIndex = 0 // frames
    private var readIndex = 0
    private let lock = NSLock() // only held for a few index updates

    init(capacityFrames: Int) {
        self.capacityFrames = capacityFrames
        buffer = Array(repeating: 0, count: capacityFrames * 2)
    }

    var availableFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return writeIndex - readIndex
    }

    func clear() {
        lock.lock(); readIndex = writeIndex; lock.unlock()
    }

    /// Writes frames; if the ring would overflow, the oldest audio is dropped.
    func write(frames: Int, _ fill: (UnsafeMutablePointer<Float>, Int) -> Void) {
        lock.lock()
        let start = writeIndex
        lock.unlock()
        buffer.withUnsafeMutableBufferPointer { ptr in
            var written = 0
            while written < frames {
                let pos = (start + written) % capacityFrames
                let run = min(frames - written, capacityFrames - pos)
                fill(ptr.baseAddress! + pos * 2, run)
                written += run
            }
        }
        lock.lock()
        writeIndex = start + frames
        if writeIndex - readIndex > capacityFrames { readIndex = writeIndex - capacityFrames }
        lock.unlock()
    }

    /// Reads up to `frames` into separate left/right buffers; pads with silence.
    /// If more than `maxLatencyFrames` are queued, the excess is skipped so the
    /// film's sound does not drift behind its picture.
    func read(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, maxLatencyFrames: Int) {
        lock.lock()
        if writeIndex - readIndex > maxLatencyFrames + frames { readIndex = writeIndex - maxLatencyFrames }
        let start = readIndex
        let available = min(frames, writeIndex - readIndex)
        readIndex += available
        lock.unlock()
        buffer.withUnsafeBufferPointer { ptr in
            for i in 0..<available {
                let pos = ((start + i) % capacityFrames) * 2
                left[i] = ptr[pos]
                right[i] = ptr[pos + 1]
            }
        }
        for i in available..<frames { left[i] = 0; right[i] = 0 }
    }
}

/// How the microphone and speakers are driven.
public enum AudioMode: String, CaseIterable, Sendable {
    /// Apple's voice processing (echo cancellation, noise suppression) on the
    /// same audio engine that plays the film and the other person's voice, so
    /// both are cancelled from the microphone.
    case voiceProcessing
    /// No voice processing: best sound, but needs headphones.
    case headphones
    /// No audio hardware at all. Generates a test tone as "microphone" and
    /// measures what arrives. Used by the integration test and screenshots.
    case synthetic
}

/// Owns the one audio engine of the app and acts as WebRTC's audio device.
///
/// WebRTC on macOS normally opens the microphone and speakers itself and
/// knows nothing about the film playing in AVPlayer, so its echo canceller
/// cannot remove the film from the microphone. Instead SameSofa plays the
/// film's sound, the other person's voice and records the microphone through
/// a single AVAudioEngine with Apple's voice processing enabled. Everything
/// that engine plays is the echo reference, so both the film and the voice
/// are cancelled before the microphone audio is handed to WebRTC.
public final class AudioHub: NSObject, RTCAudioDevice {
    public let mode: AudioMode
    static let rtcRate = 48_000.0
    static let rtcFrames10ms = 480

    private var engine: AVAudioEngine?
    private var voiceNode: AVAudioSourceNode?
    private var filmNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?
    private var converter: AVAudioConverter?
    private var syntheticTimer: DispatchSourceTimer?
    private let syntheticQueue = DispatchQueue(label: "samesofa.audio.synthetic", qos: .userInteractive)

    private weak var rtcDelegate: RTCAudioDeviceDelegate?
    private var playoutBlock: RTCAudioDeviceGetPlayoutDataBlock?
    private var deliverBlock: RTCAudioDeviceDeliverRecordedDataBlock?

    let filmRing = StereoRing(capacityFrames: 48_000 * 2)
    private var filmRate: Double = 48_000

    // Volumes, settable from the UI (0...1).
    public var filmVolume: Float = 1 { didSet { filmNode?.volume = filmVolume } }
    public var voiceVolume: Float = 1 { didSet { voiceNode?.volume = voiceVolume } }
    /// When true the microphone sends silence.
    public var micMuted = false

    // Diagnostics (read from any thread; approximate).
    public private(set) var receivedVoiceLevel: Float = 0
    public private(set) var sentFrames = 0
    public private(set) var engineError: String?

    private var _initialized = false
    private var _playoutInitialized = false
    private var _playing = false
    private var _recordingInitialized = false
    private var _recording = false
    private var scratchInt16 = [Int16](repeating: 0, count: 48_000)
    private var syntheticPhase = 0.0

    public init(mode: AudioMode) {
        self.mode = mode
        super.init()
    }

    // MARK: RTCAudioDevice: fixed 48 kHz mono 16-bit on the WebRTC side.

    public var deviceInputSampleRate: Double { Self.rtcRate }
    public var inputIOBufferDuration: TimeInterval { 0.01 }
    public var inputNumberOfChannels: Int { 1 }
    public var inputLatency: TimeInterval { 0.02 }
    public var deviceOutputSampleRate: Double { Self.rtcRate }
    public var outputIOBufferDuration: TimeInterval { 0.01 }
    public var outputNumberOfChannels: Int { 1 }
    public var outputLatency: TimeInterval { 0.02 }
    public var isInitialized: Bool { _initialized }
    public var isPlayoutInitialized: Bool { _playoutInitialized }
    public var isPlaying: Bool { _playing }
    public var isRecordingInitialized: Bool { _recordingInitialized }
    public var isRecording: Bool { _recording }

    public func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        rtcDelegate = delegate
        playoutBlock = delegate.getPlayoutData
        deliverBlock = delegate.deliverRecordedData
        _initialized = true
        return true
    }

    public func terminateDevice() -> Bool {
        _playing = false
        _recording = false
        playoutBlock = nil
        deliverBlock = nil
        rtcDelegate = nil
        _initialized = false
        return true
    }

    public func initializePlayout() -> Bool { _playoutInitialized = true; return true }
    public func startPlayout() -> Bool {
        _playing = true
        DispatchQueue.main.async { self.start() }
        return true
    }
    public func stopPlayout() -> Bool { _playing = false; return true }
    public func initializeRecording() -> Bool { _recordingInitialized = true; return true }
    public func startRecording() -> Bool {
        _recording = true
        DispatchQueue.main.async { self.start() }
        return true
    }
    public func stopRecording() -> Bool { _recording = false; return true }

    // MARK: Engine

    /// Starts the engine (idempotent). Called when the film or the call needs sound.
    public func start() {
        if mode == .synthetic { startSynthetic(); return }
        if let engine, engine.isRunning { return }
        let engine = AVAudioEngine()
        self.engine = engine
        do {
            let input = engine.inputNode
            if mode == .voiceProcessing {
                try input.setVoiceProcessingEnabled(true)
                // Do not turn other apps (or our own film) down while talking.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }

            let mono = AVAudioFormat(standardFormatWithSampleRate: Self.rtcRate, channels: 1)!
            let voice = AVAudioSourceNode(format: mono) { [weak self] _, timestamp, frames, abl in
                self?.renderVoice(frames: Int(frames), timestamp: timestamp, abl: abl) ?? noErr
            }
            voice.volume = voiceVolume
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: mono)
            voiceNode = voice

            attachFilmNode(to: engine, rate: filmRate)

            let inputFormat = input.outputFormat(forBus: 0)
            if inputFormat.sampleRate > 0, inputFormat.channelCount > 0 {
                let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.rtcRate, channels: 1, interleaved: true)!
                converter = AVAudioConverter(from: inputFormat, to: target)
                let sink = AVAudioSinkNode { [weak self] timestamp, frames, abl in
                    self?.captured(frames: frames, timestamp: timestamp, abl: abl, format: inputFormat) ?? noErr
                }
                engine.attach(sink)
                engine.connect(input, to: sink, format: inputFormat)
                sinkNode = sink
            }
            engine.prepare()
            try engine.start()
            engineError = nil
        } catch {
            engineError = "\(error)"
            NSLog("SameSofa audio engine failed: \(error)")
        }
    }

    public func stop() {
        engine?.stop()
        engine = nil
        voiceNode = nil
        filmNode = nil
        sinkNode = nil
        syntheticTimer?.cancel()
        syntheticTimer = nil
    }

    private func attachFilmNode(to engine: AVAudioEngine, rate: Double) {
        if let old = filmNode { engine.detach(old) }
        let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let maxLatency = Int(rate * 0.05)
        let ring = filmRing
        let node = AVAudioSourceNode(format: stereo) { _, _, frames, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.read(frames: Int(frames), left: left, right: right, maxLatencyFrames: maxLatency)
            return noErr
        }
        node.volume = filmVolume
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: stereo)
        filmNode = node
    }

    /// The film's sample rate became known (from the audio tap).
    func filmFormatChanged(sampleRate: Double) {
        DispatchQueue.main.async {
            guard sampleRate != self.filmRate else { return }
            self.filmRate = sampleRate
            if let engine = self.engine, self.mode != .synthetic { self.attachFilmNode(to: engine, rate: sampleRate) }
        }
    }

    private func renderVoice(frames: Int, timestamp: UnsafePointer<AudioTimeStamp>, abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let out = UnsafeMutableAudioBufferListPointer(abl)
        guard let dst = out.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        guard _playing, let playoutBlock, frames <= scratchInt16.count else {
            for i in 0..<frames { dst[i] = 0 }
            return noErr
        }
        scratchInt16.withUnsafeMutableBufferPointer { scratch in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(frames * 2), mData: UnsafeMutableRawPointer(scratch.baseAddress)))
            var flags = AudioUnitRenderActionFlags()
            _ = playoutBlock(&flags, timestamp, 0, UInt32(frames), &list)
            var peak: Float = 0
            for i in 0..<frames {
                let v = Float(scratch[i]) / 32768
                dst[i] = v
                peak = max(peak, abs(v))
            }
            receivedVoiceLevel = max(peak, receivedVoiceLevel * 0.95)
        }
        return noErr
    }

    private var convertOut: AVAudioPCMBuffer?

    private func captured(frames: AVAudioFrameCount, timestamp: UnsafePointer<AudioTimeStamp>, abl: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> OSStatus {
        guard _recording, let deliverBlock, let converter,
              let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl, deallocator: nil) else { return noErr }
        input.frameLength = frames
        let capacity = AVAudioFrameCount(Double(frames) * Self.rtcRate / format.sampleRate) + 32
        if convertOut == nil || convertOut!.frameCapacity < capacity {
            convertOut = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
        }
        guard let out = convertOut else { return noErr }
        out.frameLength = 0
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return noErr }
        if micMuted { memset(samples, 0, Int(out.frameLength) * 2) }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: out.frameLength * 2, mData: UnsafeMutableRawPointer(samples)))
        var flags = AudioUnitRenderActionFlags()
        _ = deliverBlock(&flags, timestamp, 1, out.frameLength, &list, nil, nil)
        sentFrames += Int(out.frameLength)
        return noErr
    }

    // MARK: Synthetic mode (tests and screenshots): no microphone, no speakers.

    private func startSynthetic() {
        guard syntheticTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: syntheticQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        var left = [Float](repeating: 0, count: Self.rtcFrames10ms)
        var right = [Float](repeating: 0, count: Self.rtcFrames10ms)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var ts = AudioTimeStamp()
            ts.mSampleTime = Double(self.sentFrames)
            ts.mFlags = .sampleTimeValid
            let frames = Self.rtcFrames10ms
            // "Speaker": pull the other side's voice and just measure it.
            var dummy = AudioBufferList()
            withUnsafeMutablePointer(to: &dummy) { abl in
                var floatOut = [Float](repeating: 0, count: frames)
                floatOut.withUnsafeMutableBufferPointer { fp in
                    abl.pointee = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(fp.baseAddress)))
                    _ = self.renderVoice(frames: frames, timestamp: &ts, abl: abl)
                }
            }
            // Drain the film ring as the real engine would.
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    self.filmRing.read(frames: Int(Double(frames) * self.filmRate / Self.rtcRate), left: l.baseAddress!, right: r.baseAddress!, maxLatencyFrames: Int(self.filmRate * 0.05))
                }
            }
            // "Microphone": a quiet 440 Hz tone.
            guard self._recording, let deliver = self.deliverBlock else { return }
            self.scratchInt16.withUnsafeMutableBufferPointer { scratch in
                for i in 0..<frames {
                    scratch[i] = self.micMuted ? 0 : Int16(sin(self.syntheticPhase) * 3000)
                    self.syntheticPhase += 2 * .pi * 440 / Self.rtcRate
                }
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(frames * 2), mData: UnsafeMutableRawPointer(scratch.baseAddress)))
                var flags = AudioUnitRenderActionFlags()
                _ = deliver(&flags, &ts, 1, UInt32(frames), &list, nil, nil)
            }
            self.sentFrames += frames
        }
        timer.resume()
        syntheticTimer = timer
    }
}
