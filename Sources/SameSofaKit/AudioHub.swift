import AVFoundation
import CAudioTap
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

/// What became of the microphone when the call's audio was started.
public enum MicrophoneState: Equatable, Sendable {
    /// The call's audio has not been started yet.
    case notStarted
    case working
    /// This Mac has no microphone connected.
    case noDevice
    /// macOS does not let this app use the microphone.
    case accessDenied
    /// The microphone delivers something SameSofa cannot use (detail for logs).
    case unusable(String)
}

/// Counters and facts about the running call audio, for tests and diagnostics.
public struct AudioDiagnostics: Sendable {
    public var engineRunning = false
    /// How often the output and the microphone called back since the hub was made.
    public var renderCallbacks = 0
    public var captureCallbacks = 0
    /// Loudest microphone sample since the last call of `diagnostics()` (before clean-up).
    public var capturedPeak: Float = 0
    /// What the microphone delivers, e.g. "48000 Hz, 3 channels".
    public var inputFormat: String?
    /// The microphone in use, by kind (no device names).
    public var inputDevice: String?
    /// The microphone is wired to the echo canceller and to nothing else
    /// (nil when no microphone is in use).
    public var microphoneFeedsOnlyTheCanceller: Bool?
    /// Apple's voice processing is off on both ends of the engine.
    public var voiceProcessingOff = true
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
///
/// Threads. The engine is built, watched and torn down on the main thread.
/// Two audio threads call in: the output's (`renderVoice`) and the
/// microphone's (`captured`). They share nothing with each other except the
/// voice reference ring. Each has its own buffers and its own gate; an audio
/// thread only ever *tries* its gate, so it never waits for another thread,
/// and the other threads take a gate only to hand things over when a call
/// starts or ends. Flags, volumes and counters are atomic.
public final class AudioHub: NSObject, RTCAudioDevice {
    public let mode: AudioMode
    static let rtcRate = 48_000.0
    static let rtcFrames10ms = 480
    /// The reference runs this far ahead of the clock, so that what the
    /// microphone hears always comes after what the canceller was told,
    /// whatever the output's latency really is. AEC3 finds the exact delay.
    static let referenceLead = 0.04
    private static let scratchFrames = 48_000

    // MARK: Main thread only

    private var engine: AVAudioEngine?
    private var voiceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?
    private var configurationObserver: NSObjectProtocol?
    /// The devices the running engine was built for.
    private var builtFor: AudioDeviceSignature?
    private var retryScheduled = false
    private var startFailures = 0
    private var syntheticTimer: DispatchSourceTimer?
    private let syntheticQueue = DispatchQueue(label: "samesofa.audio.synthetic", qos: .userInteractive)
    private var routeTimer: Timer?
    private var inputSummary: String?
    private var inputFormatSummary: String?

    // MARK: Shared with the audio threads (atomic)

    private let playing = AtomicBool()
    private let recording = AtomicBool()
    private let initialized = AtomicBool()
    private let playoutInitialized = AtomicBool()
    private let recordingInitialized = AtomicBool()
    private let muted = AtomicBool()
    private let cancelFilm = AtomicBool(true)
    private let filmGain = AtomicFloat(1)
    private let voiceGain = AtomicFloat(1)
    private let sentCount = AtomicInt()
    private let voicePeak = AtomicFloat()
    private let filmPeak = AtomicFloat()
    private let capturePeak = AtomicFloat()
    private let lateCount = AtomicInt()
    private let trimMilliseconds = AtomicInt()
    private let renderCount = AtomicInt()
    private let captureCount = AtomicInt()
    /// Counts films: a new one starts its reference without any trim.
    private let filmEpoch = AtomicInt()

    // MARK: The output's audio thread (behind `playoutGate`)

    private let playoutGate = OSAllocatedUnfairLock()
    private var playoutBlock: RTCAudioDeviceGetPlayoutDataBlock?
    private let playoutScratch = UnsafeMutablePointer<Int16>.allocate(capacity: AudioHub.scratchFrames)

    // MARK: The microphone's audio thread (behind `captureGate`)

    private let captureGate = OSAllocatedUnfairLock()
    private var deliverBlock: RTCAudioDeviceDeliverRecordedDataBlock?
    private var captureConverter: CaptureConverter?
    private var canceller: OpaquePointer?
    private let captureScratch = UnsafeMutablePointer<Int16>.allocate(capacity: AudioHub.rtcFrames10ms)
    private let captureQueue = UnsafeMutablePointer<Float>.allocate(capacity: AudioHub.scratchFrames)
    private var captureQueued = 0
    private let referenceLeft = UnsafeMutablePointer<Float>.allocate(capacity: AudioHub.rtcFrames10ms)
    private let referenceRight = UnsafeMutablePointer<Float>.allocate(capacity: AudioHub.rtcFrames10ms)
    private var filmCursor = ReferenceCursor(sampleRate: 48_000)
    private var voiceCursor = ReferenceCursor(sampleRate: 48_000)
    /// How much later than planned the film reference is read, because the
    /// player hands its sound over later than expected (seconds). Never more
    /// than `referenceLead`: reading at the clock's own position is still
    /// ahead of what the microphone can hear. Starts again with every film.
    private var filmLeadTrim = 0.0
    private var seenFilmEpoch = 0
    private var syntheticPhase = 0.0

    // MARK: The echo reference

    /// Stereo copy of the film's sound, positioned in film samples.
    let filmReference = TimedRing(channels: 2, capacityFrames: 192_000)
    private let voiceReference = TimedRing(channels: 1, capacityFrames: 48_000)
    private let filmClockLock = OSAllocatedUnfairLock()
    private var filmTimebase: CMTimebase?
    private var filmRate = 48_000.0

    private weak var rtcDelegate: RTCAudioDeviceDelegate?

    // MARK: Settings and state

    /// Film volume (0...1). The player applies it; here it scales the echo reference.
    public var filmVolume: Float {
        get { filmGain.value }
        set { filmGain.value = newValue }
    }
    public var voiceVolume: Float {
        get { voiceGain.value }
        set { voiceGain.value = newValue; voiceNode?.volume = newValue }
    }
    /// When true the microphone sends silence.
    public var micMuted: Bool {
        get { muted.value }
        set { muted.value = newValue }
    }
    /// "Automatic" follows the output device; the other two override it.
    public var echoSetting: EchoSetting = .automatic { didSet { updateRoute() } }
    /// The sound output in use (checked every second while live).
    public private(set) var outputRoute = OutputRoute.unknown
    /// Called on the main thread when `outputRoute`, `cancelsFilmEcho` or `microphoneState` changes.
    public var onRouteChange: (() -> Void)?
    /// Is the film's sound being removed from the microphone?
    public var cancelsFilmEcho: Bool { mode == .live && cancelFilm.value && filmClockLock.withLock { filmTimebase != nil } }
    /// Should the player let the hub listen to the film? Only when the film
    /// has to be removed from the microphone (speakers); with headphones the
    /// player's sound path has nothing of ours in it at all.
    public var wantsFilmReference: Bool { mode == .synthetic || cancelFilm.value }
    /// A call is running and the microphone is being cleaned.
    public var microphoneActive: Bool { mode == .live && recording.value && sinkNode != nil && engine?.isRunning == true }
    /// What became of the microphone the last time the call's audio was started.
    public private(set) var microphoneState = MicrophoneState.notStarted {
        didSet { if microphoneState != oldValue { onRouteChange?() } }
    }

    // Diagnostics (readable from any thread).
    public var receivedVoiceLevel: Float { voicePeak.value }
    /// Peak level of the film's sound (decays), for tests.
    public internal(set) var filmLevel: Float {
        get { filmPeak.value }
        set { filmPeak.value = newValue }
    }
    public var sentFrames: Int { sentCount.value }
    /// How often the film reference was asked for sound that had not arrived yet.
    public var filmReferenceLate: Int { lateCount.value }
    /// How much later than planned the film reference is being read (seconds).
    public var filmReferenceTrim: Double { Double(trimMilliseconds.value) / 1000 }
    /// Why the call's audio is not running, if it is not (main thread).
    public private(set) var engineError: String?
    /// How often the engine was rebuilt after a device change.
    public private(set) var engineRestarts = 0
    /// How often the engine came back after failing to start.
    public private(set) var engineRecoveries = 0

    // Test hooks (main thread).
    /// The next this many attempts to start the engine fail.
    public var failStartsForTesting = 0
    /// Keep watching the engine and the devices (off: behave like 1.2.0, which tried once).
    public var supervisionForTesting = true
    /// Record from this device instead of the preferred microphone.
    public var inputDeviceForTesting: UInt32?

    public init(mode: AudioMode) {
        self.mode = mode
        super.init()
        playoutScratch.initialize(repeating: 0, count: Self.scratchFrames)
        captureScratch.initialize(repeating: 0, count: Self.rtcFrames10ms)
        captureQueue.initialize(repeating: 0, count: Self.scratchFrames)
        referenceLeft.initialize(repeating: 0, count: Self.rtcFrames10ms)
        referenceRight.initialize(repeating: 0, count: Self.rtcFrames10ms)
        if mode == .live {
            updateRoute()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.supervise() }
            RunLoop.main.add(timer, forMode: .common)
            routeTimer = timer
        }
    }

    deinit {
        routeTimer?.invalidate()
        engine?.stop()
        if let canceller { SSEchoCancellerDestroy(canceller) }
        playoutScratch.deallocate()
        captureScratch.deallocate()
        captureQueue.deallocate()
        referenceLeft.deallocate()
        referenceRight.deallocate()
    }

    private func updateRoute() {
        guard mode == .live else { return }
        let route = OutputDevice.currentRoute()
        let cancel = echoSetting.cancelsFilmEcho(on: route)
        guard route != outputRoute || cancel != cancelFilm.value else { return }
        outputRoute = route
        cancelFilm.value = cancel
        onRouteChange?()
    }

    // MARK: The film's clock (set by PlaybackController)

    /// The clock of the film being played, or nil when there is none.
    func setFilmTimebase(_ timebase: CMTimebase?) {
        filmClockLock.withLock { filmTimebase = timebase }
        filmEpoch.add(1)
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
    public var isInitialized: Bool { initialized.value }
    public var isPlayoutInitialized: Bool { playoutInitialized.value }
    public var isPlaying: Bool { playing.value }
    public var isRecordingInitialized: Bool { recordingInitialized.value }
    public var isRecording: Bool { recording.value }

    public func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        let playout = delegate.getPlayoutData, deliver = delegate.deliverRecordedData
        playoutGate.withLockUnchecked { playoutBlock = playout }
        captureGate.withLockUnchecked { deliverBlock = deliver; rtcDelegate = delegate }
        initialized.value = true
        return true
    }

    public func terminateDevice() -> Bool {
        playing.value = false
        recording.value = false
        // Waits for a callback that is in the middle of using them (never the other way round).
        playoutGate.withLockUnchecked { playoutBlock = nil }
        captureGate.withLockUnchecked { deliverBlock = nil; rtcDelegate = nil }
        initialized.value = false
        return true
    }

    public func initializePlayout() -> Bool { playoutInitialized.value = true; return true }
    public func startPlayout() -> Bool {
        playing.value = true
        DispatchQueue.main.async { self.start() }
        return true
    }
    public func stopPlayout() -> Bool { playing.value = false; return true }
    public func initializeRecording() -> Bool { recordingInitialized.value = true; return true }
    public func startRecording() -> Bool {
        recording.value = true
        DispatchQueue.main.async { self.start() }
        return true
    }
    public func stopRecording() -> Bool { recording.value = false; return true }

    // MARK: Engine (the call's voice out, the microphone in)

    /// Starts the call's audio (idempotent; main thread). The film does not need it.
    /// If it cannot be started now (a device that is still settling), it is
    /// tried again until it runs or the call ends.
    public func start() {
        if mode == .synthetic { startSynthetic(); return }
        if let engine, engine.isRunning { return }
        teardownEngine()
        if let failure = startEngine() {
            if startFailures == 0 || engineError != failure { NSLog("SameSofa: the call's audio did not start (\(failure)); trying again") }
            engineError = failure
            startFailures += 1
            teardownEngine()
            scheduleRetry()
        } else {
            if startFailures > 0 { engineRecoveries += 1 }
            startFailures = 0
            engineError = nil
        }
    }

    private var wanted: Bool { playing.value || recording.value }

    private func scheduleRetry() {
        guard supervisionForTesting, !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            if self.wanted, self.engine == nil, self.mode == .live { self.start() }
        }
    }

    /// Every second while live: the route, and whether the engine still fits
    /// the devices. The system's notification about device changes is the
    /// normal path; this catches what it does not report (a microphone
    /// plugged in while only the output was in use, a device whose format
    /// settles late, a start that failed).
    private func supervise() {
        updateRoute()
        guard mode == .live, supervisionForTesting, wanted else { return }
        guard let engine, engine.isRunning else { start(); return }
        if let builtFor, builtFor != AudioDeviceSignature.current(pinnedInput: inputDeviceForTesting) {
            engineConfigurationChanged()
        }
    }

    private func teardownEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if engine != nil, let delegate = captureGate.withLockUnchecked({ rtcDelegate }) {
            // The next callbacks will come from other threads; WebRTC wants to be told.
            delegate.dispatchAsync { [weak delegate] in
                delegate?.notifyAudioInputInterrupted()
                delegate?.notifyAudioOutputInterrupted()
            }
        }
        engine?.stop()
        engine = nil
        voiceNode = nil
        sinkNode = nil
        builtFor = nil
        // The engine has stopped; the gate covers a callback that was still on its way out.
        var oldCanceller: OpaquePointer?
        captureGate.withLockUnchecked {
            oldCanceller = canceller
            canceller = nil
            captureConverter = nil
            captureQueued = 0
            voiceCursor.reset()
            filmCursor.reset()
        }
        if let oldCanceller { SSEchoCancellerDestroy(oldCanceller) }
        voiceReference.clear()
    }

    /// Builds and starts the engine. Returns nil, or why it could not.
    private func startEngine() -> String? {
        if failStartsForTesting > 0 {
            failStartsForTesting -= 1
            return "simulated failure"
        }
        let signature = AudioDeviceSignature.current(pinnedInput: inputDeviceForTesting)
        // Touching AVAudioEngine.inputNode without any input device raises an
        // Objective-C exception, and without permission it only records silence.
        var microphone = MicrophoneState.working
        let access = AVCaptureDevice.authorizationStatus(for: .audio)
        if signature.input == nil || AVCaptureDevice.default(for: .audio) == nil {
            microphone = .noDevice
        } else if access == .denied || access == .restricted {
            microphone = .accessDenied
        }
        let engine = AVAudioEngine()
        self.engine = engine
        var thrown: Error?
        var summary: String?, formatSummary: String?
        let exception = SSCatchException {
            let mono = AVAudioFormat(standardFormatWithSampleRate: Self.rtcRate, channels: 1)!
            let voice = AVAudioSourceNode(format: mono) { [weak self] _, timestamp, frames, abl in
                self?.renderVoice(frames: Int(frames), timestamp: timestamp, abl: abl) ?? noErr
            }
            voice.volume = self.voiceGain.value
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: mono)
            self.voiceNode = voice

            if microphone == .working, let device = signature.input {
                let input = engine.inputNode
                InputDevice.select(device, for: input)
                let inputFormat = input.outputFormat(forBus: 0)
                if inputFormat.sampleRate > 0, inputFormat.channelCount > 0 {
                    do {
                        let converter = try CaptureConverter(format: inputFormat.streamDescription.pointee)
                        let canceller = SSEchoCancellerCreate(1, 1, 1)
                        self.captureGate.withLockUnchecked {
                            self.captureConverter = converter
                            self.canceller = canceller
                            self.captureQueued = 0
                        }
                        // The microphone goes to the canceller and nowhere else: never to the mixer, never to the output.
                        let sink = AVAudioSinkNode { [weak self] timestamp, frames, abl in
                            self?.captured(frames: Int(frames), timestamp: timestamp, abl: abl) ?? noErr
                        }
                        engine.attach(sink)
                        engine.connect(input, to: sink, format: inputFormat)
                        self.sinkNode = sink
                        summary = AudioDevices.info(device, scope: kAudioDevicePropertyScopeInput).transport.rawValue
                        formatSummary = "\(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) channel\(inputFormat.channelCount == 1 ? "" : "s")"
                    } catch {
                        microphone = .unusable("\(error)")
                    }
                } else {
                    // A device that has only just appeared; the signature check builds again once it has a format.
                    microphone = .unusable("the microphone has no format yet")
                }
            }
            // Plugging in headphones, AirPods connecting, a new default device:
            // the engine stops itself and has to be rebuilt. The film is not
            // part of it and plays on.
            self.configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in self?.engineConfigurationChanged() }
            engine.prepare()
            do { try engine.start() } catch { thrown = error }
        }
        if let exception { return exception }
        if let thrown { return "\(thrown.localizedDescription)" }
        builtFor = signature
        inputSummary = summary
        inputFormatSummary = formatSummary
        microphoneState = microphone
        return nil
    }

    private func engineConfigurationChanged() {
        guard mode == .live, engine != nil else { return }
        engineRestarts += 1
        teardownEngine()
        updateRoute()
        if wanted { start() }
    }

    /// Facts about the running engine (main thread).
    public func diagnostics() -> AudioDiagnostics {
        var result = AudioDiagnostics()
        result.engineRunning = engine?.isRunning == true
        result.renderCallbacks = renderCount.value
        result.captureCallbacks = captureCount.value
        result.capturedPeak = capturePeak.value
        capturePeak.value = 0
        guard let engine else { return result }
        result.voiceProcessingOff = !engine.outputNode.isVoiceProcessingEnabled
        if let sinkNode {
            result.inputFormat = inputFormatSummary
            result.inputDevice = inputSummary
            let input = engine.inputNode
            result.voiceProcessingOff = result.voiceProcessingOff && !input.isVoiceProcessingEnabled
            let targets = engine.outputConnectionPoints(for: input, outputBus: 0)
            var onlySink = !targets.isEmpty && targets.allSatisfy { $0.node === sinkNode }
            // And nothing but the voice feeds the mixer.
            let mixer = engine.mainMixerNode
            for bus in 0..<mixer.numberOfInputs {
                if let source = engine.inputConnectionPoint(for: mixer, inputBus: bus)?.node, source !== voiceNode { onlySink = false }
            }
            result.microphoneFeedsOnlyTheCanceller = onlySink
        }
        return result
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
            right.withUnsafeMutableBufferPointer { r in
                captureGate.withLockUnchecked { mixReference(at: time, left: l.baseAddress!, right: r.baseAddress!) }
            }
        }
        return (left, right, filmTime)
    }
    /// Host clock in seconds, as used for `referenceForTesting`.
    public static var hostClockNow: Double { HostClock.now }

    /// Test hook: behave as if the sound devices had just changed.
    public func simulateDeviceChange() { engineConfigurationChanged() }

    /// Test hook: what the output's audio thread does for one buffer of
    /// `frames` frames, without an engine. Any thread.
    public func renderForTesting(frames: Int, into destination: UnsafeMutablePointer<Float>) {
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(frames * MemoryLayout<Float>.size), mData: UnsafeMutableRawPointer(destination)))
        var stamp = AudioTimeStamp()
        stamp.mHostTime = mach_absolute_time()
        stamp.mFlags = .hostTimeValid
        _ = renderVoice(frames: frames, timestamp: &stamp, abl: &list)
    }

    /// Test hook: as if WebRTC had started (or stopped) playing and recording,
    /// without starting the engine.
    public func setCallStateForTesting(playing: Bool, recording: Bool) {
        self.playing.value = playing
        self.recording.value = recording
    }

    /// Test hook: a film clock without a player (nil: no film).
    public func setFilmClockForTesting(_ timebase: CMTimebase?) { setFilmTimebase(timebase) }

    /// Test hook: sets the microphone path up for `format` without an engine
    /// (`cancelEcho`: with the echo canceller, as in a call).
    public func prepareCaptureForTesting(format: AudioStreamBasicDescription, cancelEcho: Bool) throws {
        let converter = try CaptureConverter(format: format)
        let newCanceller = cancelEcho ? SSEchoCancellerCreate(1, 1, 1) : nil
        var old: OpaquePointer?
        captureGate.withLockUnchecked {
            old = canceller
            captureConverter = converter
            canceller = newCanceller
            captureQueued = 0
        }
        if let old { SSEchoCancellerDestroy(old) }
    }

    /// Test hook: what the microphone's audio thread does for one buffer. Any thread.
    public func captureForTesting(_ buffers: UnsafePointer<AudioBufferList>, frames: Int) {
        var stamp = AudioTimeStamp()
        stamp.mHostTime = mach_absolute_time()
        stamp.mFlags = .hostTimeValid
        _ = captured(frames: frames, timestamp: &stamp, abl: buffers)
    }

    public func stop() {
        teardownEngine()
        microphoneState = .notStarted
        syntheticTimer?.cancel()
        syntheticTimer = nil
    }

    // MARK: The output's audio thread

    private func renderVoice(frames: Int, timestamp: UnsafePointer<AudioTimeStamp>, abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let out = UnsafeMutableAudioBufferListPointer(abl)
        guard let dst = out.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        renderCount.add(1)
        var filled = false
        if playing.value, frames <= Self.scratchFrames, playoutGate.lockIfAvailable() {
            if let playoutBlock {
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(frames * 2), mData: UnsafeMutableRawPointer(playoutScratch)))
                var flags = AudioUnitRenderActionFlags()
                _ = playoutBlock(&flags, timestamp, 0, UInt32(frames), &list)
                var peak: Float = 0
                for i in 0..<frames {
                    let v = Float(playoutScratch[i]) / 32768
                    dst[i] = v
                    peak = max(peak, abs(v))
                }
                voicePeak.value = max(peak, voicePeak.value * 0.95)
                filled = true
            }
            playoutGate.unlock()
        }
        if !filled { memset(dst, 0, frames * MemoryLayout<Float>.size) }
        if mode == .live {
            // Remember what the speakers are about to play, and when.
            voiceReference.append(frames: frames, hostTime: HostClock.seconds(timestamp)) { destination, offset, count in
                memcpy(destination, dst + offset, count * MemoryLayout<Float>.size)
            }
        }
        return noErr
    }

    // MARK: The microphone's audio thread

    private func captured(frames: Int, timestamp: UnsafePointer<AudioTimeStamp>, abl: UnsafePointer<AudioBufferList>) -> OSStatus {
        captureCount.add(1)
        guard recording.value, captureGate.lockIfAvailable() else { return noErr }
        defer { captureGate.unlock() }
        guard let captureConverter else { return noErr }
        let recordedAt = HostClock.seconds(timestamp)
        captureConverter.convert(abl, frames: frames) { samples, produced in
            enqueueCaptured(samples, frames: produced, recordedAt: recordedAt)
        }
        return noErr
    }

    /// 48 kHz mono microphone samples; passes them on in blocks of 10 ms.
    private func enqueueCaptured(_ samples: UnsafePointer<Float>, frames produced: Int, recordedAt: Double) {
        guard produced > 0 else { return }
        var peak = capturePeak.value
        for i in 0..<produced { peak = max(peak, abs(samples[i])) }
        capturePeak.value = peak
        // When the oldest queued sample was recorded.
        let queueStart = recordedAt - Double(captureQueued) / Self.rtcRate
        guard captureQueued + produced <= Self.scratchFrames else { captureQueued = 0; return }
        memcpy(captureQueue + captureQueued, samples, produced * MemoryLayout<Float>.size)
        captureQueued += produced
        var done = 0
        while captureQueued - done >= Self.rtcFrames10ms {
            processCapturedBlock(captureQueue + done, recordedAt: queueStart + Double(done) / Self.rtcRate)
            done += Self.rtcFrames10ms
        }
        if done > 0 {
            captureQueued -= done
            memmove(captureQueue, captureQueue + done, captureQueued * MemoryLayout<Float>.size)
        }
    }

    /// One 10 ms block of microphone audio: remove what the speakers played, hand it to WebRTC.
    private func processCapturedBlock(_ block: UnsafeMutablePointer<Float>, recordedAt time: Double) {
        let frames = Self.rtcFrames10ms
        if let canceller {
            memset(referenceLeft, 0, frames * MemoryLayout<Float>.size)
            memset(referenceRight, 0, frames * MemoryLayout<Float>.size)
            mixReference(at: time, left: referenceLeft, right: referenceRight)
            SSEchoCancellerAnalyzeRender(canceller, referenceLeft, referenceRight)
            SSEchoCancellerProcessCapture(canceller, block)
        }
        guard let deliverBlock else { return }
        if muted.value {
            memset(captureScratch, 0, frames * 2)
        } else {
            for i in 0..<frames { captureScratch[i] = Int16(max(-32768, min(32767, block[i] * 32768))) }
        }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(frames * 2), mData: UnsafeMutableRawPointer(captureScratch)))
        var flags = AudioUnitRenderActionFlags()
        var stamp = AudioTimeStamp()
        stamp.mSampleTime = Double(sentCount.value)
        stamp.mFlags = .sampleTimeValid
        _ = deliverBlock(&flags, &stamp, 1, UInt32(frames), &list, nil, nil)
        sentCount.add(frames)
    }

    /// Adds everything the speakers play around host time `time` to the
    /// reference block. Microphone thread (or a test, behind `captureGate`).
    private func mixReference(at time: Double, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let frames = Self.rtcFrames10ms
        let target = time + Self.referenceLead
        if let desired = voiceReference.position(atHostTime: target, sampleRate: Self.rtcRate) {
            let read = voiceCursor.next(desired: desired, step: 1, frames: frames)
            voiceReference.mix(start: read.start, step: read.step, frames: frames, gain: voiceGain.value, left: left, right: right)
        } else {
            voiceCursor.reset()
        }
        let epoch = filmEpoch.value
        if epoch != seenFilmEpoch {
            seenFilmEpoch = epoch
            filmLeadTrim = 0
            trimMilliseconds.value = 0
            filmCursor.reset()
        }
        let (timebase, rate) = filmClockLock.withLockUnchecked { (filmTimebase, filmRate) }
        guard cancelFilm.value, let timebase else { filmCursor.reset(); return }
        let speed = CMTimebaseGetRate(timebase)
        let now = HostClock.now
        let media = CMTimebaseGetTime(timebase).seconds
        guard speed > 0, media.isFinite else { filmCursor.reset(); return }
        filmCursor.sampleRate = rate
        let desired = (media + (target - filmLeadTrim - now) * speed) * rate
        let read = filmCursor.next(desired: desired, step: speed * rate / Self.rtcRate, frames: frames)
        let arrived = filmReference.mix(start: read.start, step: read.step, frames: frames, gain: filmGain.value, left: left, right: right)
        if !arrived {
            lateCount.add(1)
            if filmLeadTrim < Self.referenceLead {
                // Asked for film sound the player has not handed over yet: read a
                // little later from now on (the canceller re-finds the delay),
                // but never later than the clock itself.
                filmLeadTrim = min(Self.referenceLead, filmLeadTrim + 0.01)
                trimMilliseconds.value = Int((filmLeadTrim * 1000).rounded())
            }
        }
    }

    // MARK: Synthetic mode (tests and screenshots): no microphone, no speakers.

    private func startSynthetic() {
        guard syntheticTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: syntheticQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        let frames = Self.rtcFrames10ms
        let speaker = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        speaker.initialize(repeating: 0, count: frames)
        timer.setCancelHandler { speaker.deallocate() }
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var ts = AudioTimeStamp()
            ts.mSampleTime = Double(self.sentCount.value)
            ts.mFlags = .sampleTimeValid
            // "Speaker": pull the other side's voice and just measure it.
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(speaker)))
            _ = self.renderVoice(frames: frames, timestamp: &ts, abl: &list)
            // "Microphone": a quiet 440 Hz tone.
            guard self.recording.value else { return }
            self.captureGate.withLockUnchecked {
                guard let deliver = self.deliverBlock else { return }
                for i in 0..<frames {
                    self.captureScratch[i] = self.muted.value ? 0 : Int16(sin(self.syntheticPhase) * 3000)
                    self.syntheticPhase += 2 * .pi * 440 / Self.rtcRate
                }
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(frames * 2), mData: UnsafeMutableRawPointer(self.captureScratch)))
                var flags = AudioUnitRenderActionFlags()
                _ = deliver(&flags, &ts, 1, UInt32(frames), &list, nil, nil)
                self.sentCount.add(frames)
            }
        }
        timer.resume()
        syntheticTimer = timer
    }
}
