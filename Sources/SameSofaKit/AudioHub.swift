import AVFoundation
import CEchoCanceller
import CWebRTCAudioDevice
import os
import SameSofaCore
import WebRTC

/// Seconds on the host clock (the clock of `AudioTimeStamp.mHostTime` and of
/// `CMClockGetHostTimeClock`).
enum HostClock {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func seconds(_ ticks: UInt64) -> Double { Double(ticks) * secondsPerTick }
    static var now: Double { seconds(mach_absolute_time()) }

    static func seconds(_ timestamp: UnsafePointer<AudioTimeStamp>) -> Double {
        timestamp.pointee.mFlags.contains(.hostTimeValid) && timestamp.pointee.mHostTime != 0
            ? seconds(timestamp.pointee.mHostTime) : now
    }
}

/// A short history of audio with a position on a timeline, written by one
/// thread and read by another: the copy of the film's sound and of the other
/// person's voice that the echo canceller is told about.
final class TimedRing {
    let channels: Int
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var end: Int64 = 0 // position one past the newest frame
    private var count = 0 // frames held before `end`
    private var anchorHost = 0.0
    private var anchorPosition: Int64 = 0
    private var hasAnchor = false
    private let lock = OSAllocatedUnfairLock()

    init(channels: Int, capacityFrames: Int) {
        self.channels = channels
        capacity = capacityFrames
        storage = .allocate(capacity: capacityFrames * channels)
        storage.initialize(repeating: 0, count: capacityFrames * channels)
    }

    deinit { storage.deallocate() }

    func clear() {
        lock.withLock { count = 0; hasAnchor = false }
    }

    /// Appends `frames` frames. `position` is where the first one sits on the
    /// timeline (nil: right after the previous ones); a gap or a step back
    /// drops what was there. `hostTime` is when the first frame is played,
    /// for timelines that are read by clock time. `fill(destination, offset,
    /// count)` writes `count` interleaved frames starting at source frame `offset`.
    func append(frames: Int, position: Int64? = nil, hostTime: Double? = nil,
                _ fill: (UnsafeMutablePointer<Float>, Int, Int) -> Void) {
        guard frames > 0, frames <= capacity else { return }
        lock.withLock {
            if let position, abs(position - end) > 8 {
                end = position
                count = 0
            }
            if let hostTime {
                anchorHost = hostTime
                anchorPosition = end
                hasAnchor = true
            }
            var written = 0
            while written < frames {
                let slot = Int(((end + Int64(written)) % Int64(capacity) + Int64(capacity)) % Int64(capacity))
                let run = min(frames - written, capacity - slot)
                fill(storage + slot * channels, written, run)
                written += run
            }
            end += Int64(frames)
            count = min(capacity, count + frames)
        }
    }

    /// Timeline position being played at host time `time`, from the latest
    /// append that carried a host time.
    func position(atHostTime time: Double, sampleRate: Double) -> Double? {
        lock.withLock { hasAnchor ? Double(anchorPosition) + (time - anchorHost) * sampleRate : nil }
    }

    /// Adds `frames` samples to `left`/`right`, reading from fractional
    /// position `start` and advancing `step` per sample (linear
    /// interpolation). Parts outside what the ring holds add nothing.
    /// Returns false when the read ran past the newest audio (it asked for
    /// sound that has not arrived yet).
    @discardableResult
    func mix(start: Double, step: Double, frames: Int, gain: Float,
             left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        lock.withLock {
            guard count > 0 else { return true }
            let complete = Int64((start + Double(frames) * step).rounded(.up)) + 1 < end
            let first = end - Int64(count)
            let cap = Int64(capacity)
            for i in 0..<frames {
                let p = start + Double(i) * step
                let whole = p.rounded(.down)
                let index = Int64(whole)
                guard index >= first, index + 1 < end else { continue }
                let fraction = Float(p - whole)
                let a = Int(((index % cap) + cap) % cap) * channels
                let b = Int((((index + 1) % cap) + cap) % cap) * channels
                let l = storage[a] + (storage[b] - storage[a]) * fraction
                if channels >= 2 {
                    let r = storage[a + 1] + (storage[b + 1] - storage[a + 1]) * fraction
                    left[i] += l * gain
                    right[i] += r * gain
                } else {
                    left[i] += l * gain
                    right[i] += l * gain
                }
            }
            return complete
        }
    }
}

/// How the microphone and speakers are driven.
public enum AudioMode: String, CaseIterable, Sendable {
    /// Real microphone and speakers.
    case live
    /// No audio hardware at all. Generates a test tone as "microphone" and
    /// measures what arrives. Used by the integration test and screenshots.
    case synthetic
}

/// The call's audio, and WebRTC's audio device.
///
/// The film is not played here: AVPlayer plays it straight to the normal
/// sound output, untouched, whether or not a call is running. This class
/// plays the other person's voice and records the microphone through a plain
/// AVAudioEngine (no Apple voice processing, which would also process and
/// duck the film), and cleans the microphone with WebRTC's echo canceller
/// (AEC3). WebRTC inside the call only knows the voice it plays, so SameSofa
/// runs its own canceller instance and tells it everything the speakers
/// play: the voice, and a copy of the film's sound taken from the player
/// (FilmAudioTap) and lined up with the player's clock. With headphones the
/// film is left out of the reference.
public final class AudioHub: NSObject, RTCAudioDevice {
    public let mode: AudioMode
    static let rtcRate = 48_000.0
    static let rtcFrames10ms = 480
    /// The reference runs this far ahead of the clock, so that what the
    /// microphone hears always comes after what the canceller was told,
    /// whatever the output's latency really is. AEC3 finds the exact delay.
    static let referenceLead = 0.04

    private var engine: AVAudioEngine?
    private var voiceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?
    private var converter: AVAudioConverter?
    private var configurationObserver: NSObjectProtocol?
    private var syntheticTimer: DispatchSourceTimer?
    private let syntheticQueue = DispatchQueue(label: "samesofa.audio.synthetic", qos: .userInteractive)

    private weak var rtcDelegate: RTCAudioDeviceDelegate?
    private var playoutBlock: RTCAudioDeviceGetPlayoutDataBlock?
    private var deliverBlock: RTCAudioDeviceDeliverRecordedDataBlock?

    // The echo reference.
    /// Stereo copy of the film's sound, positioned in film samples.
    let filmReference = TimedRing(channels: 2, capacityFrames: 192_000)
    private let voiceReference = TimedRing(channels: 1, capacityFrames: 48_000)
    private let filmClockLock = OSAllocatedUnfairLock()
    private var filmTimebase: CMTimebase?
    private var filmRate = 48_000.0
    private var filmCursor = ReferenceCursor(sampleRate: 48_000)
    private var voiceCursor = ReferenceCursor(sampleRate: 48_000)
    private var canceller: OpaquePointer?
    private var referenceLeft = [Float](repeating: 0, count: 480)
    private var referenceRight = [Float](repeating: 0, count: 480)
    private var captureQueue = [Float](repeating: 0, count: 48_000)
    private var captureQueued = 0
    private var cancelFilm = true
    /// How much later than planned the film reference is read, because the
    /// player delivers its sound later than expected (seconds, grows only).
    private var filmLeadTrim = 0.0
    /// How often that happened (diagnostics).
    public private(set) var filmReferenceLate = 0

    /// Film volume (0...1). The player applies it; here it scales the echo reference.
    public var filmVolume: Float = 1
    public var voiceVolume: Float = 1 { didSet { voiceNode?.volume = voiceVolume } }
    /// When true the microphone sends silence.
    public var micMuted = false
    /// "Automatic" follows the output device; the other two override it.
    public var echoSetting: EchoSetting = .automatic { didSet { updateRoute() } }
    /// The sound output in use (checked every second while live).
    public private(set) var outputRoute = OutputRoute.unknown
    /// Called on the main thread when `outputRoute` or `cancelsFilmEcho` changes.
    public var onRouteChange: (() -> Void)?
    /// Is the film's sound being removed from the microphone?
    public var cancelsFilmEcho: Bool { mode == .live && cancelFilm && filmClockLock.withLock { filmTimebase != nil } }
    /// Should the player let the hub listen to the film? Only when the film
    /// has to be removed from the microphone (speakers); with headphones the
    /// player's sound path has nothing of ours in it at all.
    public var wantsFilmReference: Bool { mode == .synthetic || cancelFilm }
    /// A call is running and the microphone is being cleaned.
    public var microphoneActive: Bool { mode == .live && _recording && sinkNode != nil && engine?.isRunning == true }
    private var routeTimer: Timer?

    // Diagnostics (read from any thread; approximate).
    public private(set) var receivedVoiceLevel: Float = 0
    /// Peak level of the film's sound (decays), for tests.
    public internal(set) var filmLevel: Float = 0
    public private(set) var sentFrames = 0
    public private(set) var engineError: String?
    /// How often the engine was rebuilt after a device change.
    public private(set) var engineRestarts = 0

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
        if mode == .live {
            updateRoute()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateRoute() }
            RunLoop.main.add(timer, forMode: .common)
            routeTimer = timer
        }
    }

    deinit {
        routeTimer?.invalidate()
        if let canceller { SSEchoCancellerDestroy(canceller) }
    }

    private func updateRoute() {
        guard mode == .live else { return }
        let route = OutputDevice.currentRoute()
        let cancel = echoSetting.cancelsFilmEcho(on: route)
        guard route != outputRoute || cancel != cancelFilm else { return }
        outputRoute = route
        cancelFilm = cancel
        onRouteChange?()
    }

    // MARK: The film's clock (set by PlaybackController)

    /// The clock of the film being played, or nil when there is none.
    func setFilmTimebase(_ timebase: CMTimebase?) {
        filmClockLock.withLock { filmTimebase = timebase }
        if timebase == nil { filmReference.clear() }
    }

    /// The film's sample rate became known (from the audio tap).
    func filmFormatChanged(sampleRate: Double) {
        filmClockLock.withLock { filmRate = sampleRate }
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

    // MARK: Engine (the call's voice out, the microphone in)

    /// Starts the call's audio (idempotent). The film does not need it.
    public func start() {
        if mode == .synthetic { startSynthetic(); return }
        if let engine, engine.isRunning { return }
        teardownEngine()
        if let error = startEngine() {
            engineError = "\(error)"
            NSLog("SameSofa audio engine failed: \(error)")
            teardownEngine()
        }
    }

    private func teardownEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine = nil
        voiceNode = nil
        sinkNode = nil
        converter = nil
        // The engine has stopped calling back, so nothing is using these.
        if let canceller { SSEchoCancellerDestroy(canceller) }
        canceller = nil
        captureQueued = 0
        voiceReference.clear()
        voiceCursor.reset()
        filmCursor.reset()
    }

    private func startEngine() -> Error? {
        // Touching AVAudioEngine.inputNode without any input device raises an
        // Objective-C exception, so check first.
        let hasMicrophone = AVCaptureDevice.default(for: .audio) != nil
        let engine = AVAudioEngine()
        self.engine = engine
        do {
            let mono = AVAudioFormat(standardFormatWithSampleRate: Self.rtcRate, channels: 1)!
            let voice = AVAudioSourceNode(format: mono) { [weak self] _, timestamp, frames, abl in
                self?.renderVoice(frames: Int(frames), timestamp: timestamp, abl: abl) ?? noErr
            }
            voice.volume = voiceVolume
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: mono)
            voiceNode = voice

            if hasMicrophone {
                let input = engine.inputNode
                InputDevice.preferBuiltInOverBluetooth(for: input)
                let inputFormat = input.outputFormat(forBus: 0)
                if inputFormat.sampleRate > 0, inputFormat.channelCount > 0 {
                    converter = AVAudioConverter(from: inputFormat, to: mono)
                    canceller = SSEchoCancellerCreate(1, 1, 1)
                    let sink = AVAudioSinkNode { [weak self] timestamp, frames, abl in
                        self?.captured(frames: frames, timestamp: timestamp, abl: abl, format: inputFormat) ?? noErr
                    }
                    engine.attach(sink)
                    engine.connect(input, to: sink, format: inputFormat)
                    sinkNode = sink
                }
            }
            // Plugging in headphones, AirPods connecting, a new default device:
            // the engine stops itself and has to be rebuilt. The film is not
            // part of it and plays on.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in self?.engineConfigurationChanged() }
            engine.prepare()
            try engine.start()
            engineError = nil
            return nil
        } catch {
            return error
        }
    }

    private func engineConfigurationChanged() {
        guard mode == .live, engine != nil else { return }
        engineRestarts += 1
        teardownEngine()
        updateRoute()
        if _playing || _recording { start() }
    }

    /// Test hook: the echo reference (10 ms, 480 frames per channel) for a
    /// microphone block recorded at host time `time`, and the film position
    /// (seconds) the film's clock showed at that moment.
    public func referenceForTesting(atHostTime time: Double) -> (left: [Float], right: [Float], filmTime: Double?) {
        var left = [Float](repeating: 0, count: Self.rtcFrames10ms), right = left
        var filmTime: Double?
        if let timebase = filmClockLock.withLock({ filmTimebase }) {
            filmTime = CMTimebaseGetTime(timebase).seconds + (time - HostClock.now) * CMTimebaseGetRate(timebase)
        }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in mixReference(at: time, left: l.baseAddress!, right: r.baseAddress!) }
        }
        return (left, right, filmTime)
    }
    /// Host clock in seconds, as used for `referenceForTesting`.
    public static var hostClockNow: Double { HostClock.now }

    /// Test hook: behave as if the sound devices had just changed.
    public func simulateDeviceChange() { engineConfigurationChanged() }

    public func stop() {
        teardownEngine()
        syntheticTimer?.cancel()
        syntheticTimer = nil
    }

    private func renderVoice(frames: Int, timestamp: UnsafePointer<AudioTimeStamp>, abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let out = UnsafeMutableAudioBufferListPointer(abl)
        guard let dst = out.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        if _playing, let playoutBlock, frames <= scratchInt16.count {
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
        } else {
            for i in 0..<frames { dst[i] = 0 }
        }
        if mode == .live {
            // Remember what the speakers are about to play, and when.
            voiceReference.append(frames: frames, hostTime: HostClock.seconds(timestamp)) { destination, offset, count in
                memcpy(destination, dst + offset, count * MemoryLayout<Float>.size)
            }
        }
        return noErr
    }

    private var convertOut: AVAudioPCMBuffer?

    private func captured(frames: AVAudioFrameCount, timestamp: UnsafePointer<AudioTimeStamp>, abl: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> OSStatus {
        guard _recording, let converter,
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
        let produced = Int(out.frameLength)
        guard produced > 0, let samples = out.floatChannelData?[0] else { return noErr }
        // When the oldest queued sample was recorded.
        let queueStart = HostClock.seconds(timestamp) - Double(captureQueued) / Self.rtcRate
        captureQueue.withUnsafeMutableBufferPointer { queue in
            guard let base = queue.baseAddress, captureQueued + produced <= queue.count else { captureQueued = 0; return }
            memcpy(base + captureQueued, samples, produced * MemoryLayout<Float>.size)
            captureQueued += produced
            var done = 0
            while captureQueued - done >= Self.rtcFrames10ms {
                processCapturedBlock(base + done, recordedAt: queueStart + Double(done) / Self.rtcRate)
                done += Self.rtcFrames10ms
            }
            if done > 0 {
                captureQueued -= done
                memmove(base, base + done, captureQueued * MemoryLayout<Float>.size)
            }
        }
        return noErr
    }

    /// One 10 ms block of microphone audio: remove what the speakers played, hand it to WebRTC.
    private func processCapturedBlock(_ block: UnsafeMutablePointer<Float>, recordedAt time: Double) {
        let frames = Self.rtcFrames10ms
        if let canceller {
            referenceLeft.withUnsafeMutableBufferPointer { left in
                referenceRight.withUnsafeMutableBufferPointer { right in
                    memset(left.baseAddress!, 0, frames * MemoryLayout<Float>.size)
                    memset(right.baseAddress!, 0, frames * MemoryLayout<Float>.size)
                    mixReference(at: time, left: left.baseAddress!, right: right.baseAddress!)
                    SSEchoCancellerAnalyzeRender(canceller, left.baseAddress!, right.baseAddress!)
                }
            }
            SSEchoCancellerProcessCapture(canceller, block)
        }
        guard let deliverBlock else { return }
        scratchInt16.withUnsafeMutableBufferPointer { scratch in
            if micMuted {
                memset(scratch.baseAddress!, 0, frames * 2)
            } else {
                for i in 0..<frames { scratch[i] = Int16(max(-32768, min(32767, block[i] * 32768))) }
            }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(frames * 2), mData: UnsafeMutableRawPointer(scratch.baseAddress)))
            var flags = AudioUnitRenderActionFlags()
            var stamp = AudioTimeStamp()
            stamp.mSampleTime = Double(sentFrames)
            stamp.mFlags = .sampleTimeValid
            _ = deliverBlock(&flags, &stamp, 1, UInt32(frames), &list, nil, nil)
        }
        sentFrames += frames
    }

    /// Adds everything the speakers play around host time `time` to the reference block.
    func mixReference(at time: Double, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let frames = Self.rtcFrames10ms
        let target = time + Self.referenceLead
        if let desired = voiceReference.position(atHostTime: target, sampleRate: Self.rtcRate) {
            let read = voiceCursor.next(desired: desired, step: 1, frames: frames)
            voiceReference.mix(start: read.start, step: read.step, frames: frames, gain: voiceVolume, left: left, right: right)
        } else {
            voiceCursor.reset()
        }
        let (timebase, rate) = filmClockLock.withLock { (filmTimebase, filmRate) }
        guard cancelFilm, let timebase else { filmCursor.reset(); return }
        let speed = CMTimebaseGetRate(timebase)
        let now = HostClock.now
        let media = CMTimebaseGetTime(timebase).seconds
        guard speed > 0, media.isFinite else { filmCursor.reset(); return }
        filmCursor.sampleRate = rate
        let desired = (media + (target - filmLeadTrim - now) * speed) * rate
        let read = filmCursor.next(desired: desired, step: speed * rate / Self.rtcRate, frames: frames)
        let arrived = filmReference.mix(start: read.start, step: read.step, frames: frames, gain: filmVolume, left: left, right: right)
        if !arrived, filmLeadTrim < 0.2 {
            // Asked for film sound the player has not handed over yet: read a
            // little later from now on (the canceller re-finds the delay).
            filmLeadTrim += 0.01
            filmReferenceLate += 1
        }
    }

    // MARK: Synthetic mode (tests and screenshots): no microphone, no speakers.

    private func startSynthetic() {
        guard syntheticTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: syntheticQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
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
