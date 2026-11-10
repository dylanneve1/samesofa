import Accelerate
import AVFoundation
import CEchoCanceller
import Foundation

// Offline simulation of the film echo canceller (no microphone, no sound):
//
//   samesofa-itest --echo-sim film.wav,talker.wav
//
// The "speakers" play the film (stereo). The "microphone" hears it through a
// synthetic room (a different decaying impulse response per speaker, after a
// delay), plus a person talking in the room during part of the run. The
// canceller gets the film as its reference, 40 ms early as in the app.
// Reported: how much of the film is removed while nobody talks (ERLE), and
// whether the talker survives while the film is playing (double talk),
// compared with the same microphone clean-up in a room without film echo.
// A real room, real speakers and a real microphone are not simulated.

enum EchoSim {
    static func load(_ url: URL) -> (channels: [[Float]], rate: Double)? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        return ((0..<Int(file.processingFormat.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) },
                file.processingFormat.sampleRate)
    }

    struct Generator {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
        }
    }

    /// Decaying noise: `delay` s of silence, a direct sound, then a tail of `length` s.
    static func room(seed: UInt64, delay: Double, length: Double, gain: Float) -> [Float] {
        var generator = Generator(state: seed)
        let lead = Int(delay * 48_000), tail = Int(length * 48_000)
        var h = [Float](repeating: 0, count: lead + tail)
        h[lead] = 1
        for i in 1..<tail { h[lead + i] = generator.next() * 0.35 * exp(-Float(i) / Float(tail) * 6) }
        return h.map { $0 * gain }
    }

    static func convolve(_ x: [Float], _ h: [Float]) -> [Float] {
        let padded = [Float](repeating: 0, count: h.count - 1) + x
        var out = [Float](repeating: 0, count: x.count)
        vDSP_conv(padded, 1, Array(h.reversed()), 1, &out, 1, vDSP_Length(x.count), vDSP_Length(h.count))
        return out
    }

    static func power(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        var sum = 0.0
        for v in x { sum += Double(v) * Double(v) }
        return sum / Double(x.count)
    }

    struct Scenario {
        var name: String
        var stereoReference = true
        /// Extra delay of the speakers after the reference (output latency), seconds.
        var outputDelay = 0.0
        /// Speaker distortion (soft clipping).
        var distortion = false
        /// How loud the film is at the microphone compared with the person talking (dB).
        var echoOverTalker = 0.0
        /// Counts towards the pass/fail verdict.
        var judged = true
    }

    static func run(filmURL: URL, talkerURL: URL, dump: URL?) -> Never {
        guard let film = load(filmURL), let talk = load(talkerURL), film.rate == 48_000, talk.rate == 48_000, film.channels.count == 2 else {
            print("echo-sim needs a 48 kHz stereo film and a 48 kHz talker")
            exit(2)
        }
        let n = film.channels[0].count / 480 * 480
        let seconds = Double(n) / 48_000
        // Talker: silent until 40 % of the run, then talking (looped) to the end.
        let talkStart = Int(seconds * 0.4) * 48_000
        var talker = [Float](repeating: 0, count: n)
        for i in talkStart..<n { talker[i] = talk.channels[0][(i - talkStart) % talk.channels[0].count] }
        // A person talking near the microphone: about -26 dBFS.
        let talkerGain = Float((pow(10, -26.0 / 20) / max(power(talker[talkStart..<n]).squareRoot(), 1e-9)))
        talker = talker.map { $0 * talkerGain }
        print(String(format: "film %.1f s stereo; talker from %.1f s; reference 40 ms ahead of the microphone", seconds, Double(talkStart) / 48_000))

        let scenarios = [
            Scenario(name: "film as loud as the talker at the microphone"),
            Scenario(name: "film 10 dB quieter than the talker", echoOverTalker: -10),
            Scenario(name: "film 10 dB louder than the talker (hard case, not judged)", echoOverTalker: 10, judged: false),
            Scenario(name: "60 ms more output latency", outputDelay: 0.06),
            Scenario(name: "speaker distortion", distortion: true),
            Scenario(name: "mono reference (for comparison, not judged)", stereoReference: false, judged: false),
        ]
        var worstSingle = Double.infinity, worstTalker = Double.infinity
        for scenario in scenarios {
            var left = Array(film.channels[0][0..<n]), right = Array(film.channels[1][0..<n])
            if scenario.distortion {
                left = left.map { tanh($0 * 2.5) / 2.5 }
                right = right.map { tanh($0 * 2.5) / 2.5 }
            }
            // Reference is 40 ms early; sound travels a little; the two speakers have different paths.
            let delay = 0.04 + 0.003 + scenario.outputDelay
            var echo = zip(convolve(left, room(seed: 1, delay: delay, length: 0.12, gain: 0.5)),
                           convolve(right, room(seed: 2, delay: delay + 0.0004, length: 0.12, gain: 0.45))).map { $0 + $1 }
            let echoGain = Float(pow(10, scenario.echoOverTalker / 20) * (power(talker[talkStart..<n]) / max(power(echo[talkStart..<n]), 1e-12)).squareRoot())
            echo = echo.map { $0 * echoGain }
            var noise = Generator(state: 99)
            var microphone = [Float](repeating: 0, count: n)
            for i in 0..<n { microphone[i] = echo[i] + talker[i] + noise.next() * 0.0005 }

            let refLeft = Array(film.channels[0][0..<n]), refRight = Array(film.channels[1][0..<n])
            let refMono = zip(refLeft, refRight).map { ($0 + $1) * 0.5 }
            var delayMs: Int32 = 0
            func process(_ input: [Float]) -> [Float] {
                guard let canceller = SSEchoCancellerCreate(scenario.stereoReference ? 1 : 0, 1, 0) else { print("cannot create canceller"); exit(1) }
                var out = input
                out.withUnsafeMutableBufferPointer { output in
                    for block in 0..<(n / 480) {
                        let at = block * 480
                        if scenario.stereoReference {
                            refLeft.withUnsafeBufferPointer { l in refRight.withUnsafeBufferPointer { r in
                                _ = SSEchoCancellerAnalyzeRender(canceller, l.baseAddress! + at, r.baseAddress! + at)
                            } }
                        } else {
                            refMono.withUnsafeBufferPointer { m in _ = SSEchoCancellerAnalyzeRender(canceller, m.baseAddress! + at, nil) }
                        }
                        _ = SSEchoCancellerProcessCapture(canceller, output.baseAddress! + at)
                    }
                }
                var erle = 0.0
                SSEchoCancellerGetStats(canceller, &erle, &delayMs)
                SSEchoCancellerDestroy(canceller)
                return out
            }
            let out = process(microphone)
            // The yardstick for the talker: the same clean-up (noise suppression, filters)
            // with the same film playing, but in a room where the microphone hears no film at all.
            var quietRoom = [Float](repeating: 0, count: n)
            for i in 0..<n { quietRoom[i] = talker[i] + (microphone[i] - echo[i] - talker[i]) }
            let ideal = process(quietRoom)

            // Film only: from 4 s (converged) until the talker starts.
            let single = (4 * 48_000)..<talkStart
            let singleERLE = 10 * log10(power(echo[single]) / max(power(out[single]), 1e-12))
            // First second after the start: how fast it gets going.
            let early = 10 * log10(power(echo[24_000..<72_000]) / max(power(out[24_000..<72_000]), 1e-12))
            // Double talk: how much of the talker is left, and how alike it is.
            let double = (talkStart + 48_000)..<n
            var dot = 0.0, a = 0.0, b = 0.0
            for i in double { let x = Double(ideal[i]), y = Double(out[i]); dot += x * y; a += x * x; b += y * y }
            let bestCorrelation = dot / max((a * b).squareRoot(), 1e-12)
            let talkerLevel = 10 * log10(max(power(out[double]), 1e-12) / max(power(ideal[double]), 1e-12))
            let echoToTalker = 10 * log10(power(echo[double]) / power(talker[double]))
            print(String(format: "%@\n   film only: echo reduced by %.1f dB (0.5-1.5 s after start: %.1f dB); canceller's own delay estimate %d ms",
                         scenario.name, singleERLE, early, delayMs))
            print(String(format: "   double talk (film %+.1f dB relative to talker at the microphone): talker comes out at %+.1f dB and correlates %.2f with what the same clean-up gives in a room with no film echo",
                         echoToTalker, talkerLevel, bestCorrelation))
            if scenario.judged {
                worstSingle = min(worstSingle, singleERLE)
                worstTalker = min(worstTalker, bestCorrelation)
            }
            if let dump {
                let safe = scenario.name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "+", with: "and")
                for (suffix, signal) in [("mic", microphone), ("out", out), ("talker", talker), ("ideal", ideal)] {
                    try? signal.withUnsafeBytes { Data($0) }.write(to: dump.appendingPathComponent("\(safe)-\(suffix).f32"))
                }
            }
        }
        let ok = worstSingle >= 25 && worstTalker >= 0.8
        print(String(format: "RESULT %@: worst film-only reduction %.1f dB, worst talker correlation %.2f (judged scenarios)",
                     ok ? "PASS" : "FAIL", worstSingle, worstTalker))
        exit(ok ? 0 : 1)
    }
}
