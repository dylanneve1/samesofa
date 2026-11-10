import Accelerate
import AVFoundation
import Foundation
import SameSofaCore
import SameSofaKit

// Measures the film's sound path without making a sound:
//
//   samesofa-itest --audio-measure a.m4a,b.mp4 [--reference-ffmpeg /path/to/ffmpeg]
//
// For each file it compares
//   1. what the player goes on to play (taken at the point where SameSofa
//      listens in, during real AVPlayer playback, muted) with the decoded
//      source: the null test for "nothing of ours changes the sound";
//   2. the same listening tap inside AVFoundation's offline renderer, folded
//      down to stereo by the system, with the decoded source: level and the
//      fold-down coefficients the system uses;
//   3. what SameSofa 1.1.0 did to the same channels before handing them to
//      Apple's voice-processing output (its own fold-down, reproduced here).
// What cannot be captured offline is the last step, the system's sound
// output itself (and, for 1.1.0, Apple's voice processing).

struct DecodedAudio {
    var channels = 0
    var rate = 0.0
    var samples: [Float] = [] // interleaved
    var frames: Int { channels > 0 ? samples.count / channels : 0 }
    func channel(_ index: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames { out[i] = samples[i * channels + index] }
        return out
    }
}

enum FilmPathMeasure {
    static func firstAudioTrack(_ asset: AVAsset) -> AVAssetTrack? {
        var track: AVAssetTrack?
        let done = DispatchSemaphore(value: 0)
        Task { track = try? await asset.loadTracks(withMediaType: .audio).first; done.signal() }
        done.wait()
        return track
    }

    /// Decodes the sound track with AVAssetReader. `mix`/`stereo`: through an audio mix, folded down to stereo.
    static func decode(_ url: URL, mix: AVAudioMix? = nil, stereo: Bool = false) -> DecodedAudio? {
        let asset = AVURLAsset(url: url)
        guard let track = firstAudioTrack(asset), let reader = try? AVAssetReader(asset: asset) else { return nil }
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let output: AVAssetReaderOutput
        if stereo || mix != nil {
            if stereo {
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
                settings[AVNumberOfChannelsKey] = 2
                settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            }
            let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
            mixOutput.audioMix = mix
            output = mixOutput
        } else {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var decoded = DecodedAudio()
        while let buffer = output.copyNextSampleBuffer() {
            if decoded.channels == 0, let format = CMSampleBufferGetFormatDescription(buffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                decoded.channels = Int(asbd.mChannelsPerFrame)
                decoded.rate = asbd.mSampleRate
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            decoded.samples += chunk
        }
        return decoded.channels > 0 ? decoded : nil
    }

    /// What reached the listening point during playback.
    final class Capture {
        let lock = NSLock()
        var chunks: [(position: Int64, frames: Int, data: [Float])] = [] // interleaved
        var channels = 0
        var discontinuities = 0
        private var expected: Int64?

        func monitor() -> FilmAudioMonitor {
            { [self] buffers, frames, channels, position in
                var data = [Float](repeating: 0, count: frames * channels)
                if buffers.count >= channels {
                    for c in 0..<channels {
                        guard let source = buffers[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for i in 0..<frames { data[i * channels + c] = source[i] }
                    }
                } else if let source = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<(frames * channels) { data[i] = source[i] }
                }
                lock.lock()
                self.channels = channels
                if let position {
                    if let expected, abs(expected - position) > 8 { discontinuities += 1 }
                    expected = position + Int64(frames)
                    chunks.append((position, frames, data))
                }
                lock.unlock()
            }
        }

        var snapshot: (chunks: [(position: Int64, frames: Int, data: [Float])], discontinuities: Int) {
            lock.lock(); defer { lock.unlock() }
            return (chunks, discontinuities)
        }
    }

    static func rms(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return 0 }
        var sum = 0.0
        for v in x { sum += Double(v) * Double(v) }
        return (sum / Double(x.count)).squareRoot()
    }

    static func dB(_ ratio: Double) -> String { ratio > 0 ? String(format: "%+.2f dB", 20 * log10(ratio)) : "-inf dB" }

    /// Amplitude of the `frequency` component of `x`.
    static func tone(_ x: [Float], frequency: Double, rate: Double) -> Double {
        var re = 0.0, im = 0.0
        // Whole number of cycles, skipping the edges.
        let skip = min(x.count / 10, 4800)
        let usable = min(x.count - 2 * skip, 240_000)
        guard usable > 0 else { return 0 }
        let cycles = (Double(usable) * frequency / rate).rounded(.down)
        let n = Int(cycles * rate / frequency)
        guard n > 0 else { return 0 }
        let w = 2 * Double.pi * frequency / rate
        for i in 0..<n {
            let v = Double(x[skip + i])
            re += v * cos(w * Double(i))
            im += v * sin(w * Double(i))
        }
        return 2 * (re * re + im * im).squareRoot() / Double(n)
    }

    /// SameSofa 1.1.0's own fold-down (FilmAudioTap.copy), verbatim: it took the
    /// channels in the order the player delivers them and assumed L R C LFE Ls Rs.
    static func legacyDownmix(_ source: DecodedAudio) -> DecodedAudio {
        var out = DecodedAudio(channels: 2, rate: source.rate, samples: [Float](repeating: 0, count: source.frames * 2))
        let channels = source.channels
        func sample(_ channel: Int, _ frame: Int) -> Float { source.samples[frame * channels + channel] }
        for f in 0..<source.frames {
            var l: Float, r: Float
            switch channels {
            case 1:
                l = sample(0, f); r = l
            case 6:
                let c = sample(2, f) * 0.707
                l = sample(0, f) + c + sample(4, f) * 0.707
                r = sample(1, f) + c + sample(5, f) * 0.707
                l *= 0.6; r *= 0.6
            default:
                l = sample(0, f); r = sample(1, f)
            }
            out.samples[f * 2] = l
            out.samples[f * 2 + 1] = r
        }
        return out
    }

    static func run(files: [URL], referenceFFmpeg: String?, seconds: Double = 5) -> Never {
        var allExact = true
        for url in files {
            print("== \(url.lastPathComponent)")
            guard let source = decode(url) else { print("   cannot decode"); allExact = false; continue }
            print(String(format: "   source: %d ch, %.0f Hz, %.2f s", source.channels, source.rate, Double(source.frames) / source.rate))

            // 1. Real playback (muted), listening where the player hands the sound on.
            let capture = Capture()
            let hub = AudioHub(mode: .synthetic)
            let controller = PlaybackController(role: .host, hub: hub)
            controller.filmAudioMonitor = capture.monitor()
            controller.load(asset: AVURLAsset(url: url))
            let ready = Date().addingTimeInterval(10)
            while !controller.isLoaded, Date() < ready { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            controller.play()
            // While it plays: does the film's clock run steadily (no stalls, no jumps)?
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            var clockStart: (host: Double, film: Double)?, worstClock = 0.0
            // The echo reference, pulled in 10 ms blocks as the microphone path would (first 3 s only).
            var reference: [Float] = [], referenceFilmStart: Double?
            var nextBlock = AudioHub.hostClockNow
            let playUntil = Date().addingTimeInterval(seconds)
            while Date() < playUntil {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                while reference.count < 3 * 48_000, nextBlock <= AudioHub.hostClockNow {
                    let block = hub.referenceForTesting(atHostTime: nextBlock)
                    if referenceFilmStart == nil { referenceFilmStart = block.filmTime }
                    reference += block.left
                    nextBlock += 0.01
                }
                guard let timebase = controller.player.currentItem?.timebase else { continue }
                let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds, film = CMTimebaseGetTime(timebase).seconds
                if let clockStart { worstClock = max(worstClock, abs((film - clockStart.film) - (now - clockStart.host))) } else { clockStart = (now, film) }
            }
            let rate = controller.player.rate
            // Taken while still playing: pausing seeks, which restarts the sound on purpose.
            let played = capture.snapshot
            controller.pause()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            controller.unload()
            var compared = 0, maxDifference: Float = 0
            var differenceEnergy = 0.0, signalEnergy = 0.0
            // Where in the decoded source does the captured sound sit? (0 when the positions are right.)
            var lag = 0
            if let probe = played.chunks.first(where: { $0.position > 48_000 && Int($0.position) + $0.frames + 12_100 < source.frames && rms($0.data) > 0.001 }) {
                func difference(_ candidate: Int) -> Double {
                    let base = (Int(probe.position) + candidate) * source.channels
                    guard base >= 0 else { return .infinity }
                    var sum = 0.0
                    for i in 0..<min(probe.data.count, 1024) { sum += Double(abs(probe.data[i] - source.samples[base + i])) }
                    return sum
                }
                var best = difference(0)
                if best > 0 {
                    for candidate in -12_000...12_000 where difference(candidate) < best { best = difference(candidate); lag = candidate }
                }
            }
            // Dropped or repeated sound shows as a jump in position between buffers (start-up aside).
            var breaks = 0
            let steady = played.chunks.filter { $0.position > Int64(source.rate) }
            for (a, b) in zip(steady, steady.dropFirst()) where abs(a.position + Int64(a.frames) - b.position) > 8 { breaks += 1 }
            if ProcessInfo.processInfo.environment["MEASURE_DEBUG"] != nil {
                var previousEnd: Int64 = 0
                for chunk in played.chunks.prefix(14) {
                    var best = Double.infinity, bestLag = 0
                    for candidate in stride(from: -12000, through: 12000, by: 1) {
                        let base = (Int(chunk.position) + candidate) * source.channels
                        guard base >= 0, base + 512 <= source.samples.count else { continue }
                        var sum = 0.0
                        for i in 0..<512 { sum += Double(abs(chunk.data[i] - source.samples[base + i])) }
                        if sum < best { best = sum; bestLag = candidate }
                    }
                    print("      chunk at \(chunk.position) (+\(chunk.position - previousEnd) after previous end) frames \(chunk.frames): best lag \(bestLag), difference \(best)")
                    previousEnd = chunk.position + Int64(chunk.frames)
                }
            }
            for chunk in steady {
                let base = (Int(chunk.position) + lag) * source.channels
                guard base >= 0, base + chunk.data.count <= source.samples.count, capture.channels == source.channels else { continue }
                for i in 0..<chunk.data.count {
                    let d = chunk.data[i] - source.samples[base + i]
                    maxDifference = max(maxDifference, abs(d))
                    differenceEnergy += Double(d) * Double(d)
                    signalEnergy += Double(source.samples[base + i]) * Double(source.samples[base + i])
                }
                compared += chunk.frames
            }
            let exact = compared > 0 && maxDifference == 0
            if !exact { allExact = false }
            if breaks != 0 || lag != 0 || worstClock > 0.005 || controller.audioSetupCount != 1 { allExact = false }
            print(String(format: "   new path, player -> output stage over %.0f s: %d frames compared (offset %d), rate %.3f, %d dropped/repeated stretches, film clock within %.2f ms of real time, sound set up %d time(s)",
                         seconds, compared, lag, rate, breaks, worstClock * 1000, controller.audioSetupCount))
            print("      null test vs decoded source: " + (exact ? "BIT-EXACT (max difference 0)" :
                String(format: "max difference %.3g, residual %@", maxDifference, signalEnergy > 0 ? dB((differenceEnergy / signalEnergy).squareRoot()) : "n/a")))

            // 1b. The echo reference: is it the film's sound, at the moment the film's clock says it is playing?
            if source.channels == 2, source.rate == 48_000, let filmStart = referenceFilmStart, reference.count >= 96_000 {
                let sourceLeft = source.channel(0)
                // Skip the first second (start-up), then find where a stretch of the reference sits in the source.
                let from = 48_000, length = 4800
                let expected = Int((filmStart + 1.0) * 48_000)
                var best = -1.0, bestOffset = 0
                for offset in stride(from: -9600, through: 9600, by: 1) {
                    let base = expected + offset
                    guard base >= 0, base + length < sourceLeft.count else { continue }
                    var dot = 0.0, a = 0.0, b = 0.0
                    for i in stride(from: 0, to: length, by: 3) {
                        let x = Double(reference[from + i]), y = Double(sourceLeft[base + i])
                        dot += x * y; a += x * x; b += y * y
                    }
                    let c = dot / max((a * b).squareRoot(), 1e-12)
                    if c > best { best = c; bestOffset = offset }
                }
                // Over the whole stretch after start-up: does the reference stay locked to the source?
                var dot = 0.0, a = 0.0, b = 0.0
                let base = expected + bestOffset
                for i in 0..<(reference.count - from) where base + i < sourceLeft.count && base + i >= 0 {
                    let x = Double(reference[from + i]), y = Double(sourceLeft[base + i])
                    dot += x * y; a += x * x; b += y * y
                }
                let overall = dot / max((a * b).squareRoot(), 1e-12)
                let lead = Double(bestOffset) / 48
                let fine = best > 0.95 && overall > 0.9 && lead > 30 && lead < 50 && hub.filmReferenceLate == 0
                if !fine, rms(Array(sourceLeft[max(0, base)..<min(sourceLeft.count, max(0, base) + length)])) > 0.001 { allExact = false }
                print(String(format: "   echo reference: matches the film's sound (correlation %.3f on 100 ms, %.3f over %.1f s), running %.1f ms ahead of the film's clock (planned 40), asked for sound that had not arrived %d times",
                             best, overall, Double(reference.count - from) / 48_000, lead, hub.filmReferenceLate))
            }
            // 2. The listening tap inside AVFoundation's offline renderer, folded to stereo by the system.
            var mix: AVAudioMix?
            if let track = firstAudioTrack(AVURLAsset(url: url)) {
                let done = DispatchSemaphore(value: 0)
                Task { mix = await FilmListening.audioMix(for: track, hub: hub); done.signal() }
                done.wait()
            }
            let tones: [Double] = [80, 440, 550, 660, 770, 880, 990, 1100]
            func gains(_ stereo: DecodedAudio, label: String) {
                let left = stereo.channel(0), right = stereo.channel(1)
                for c in 0..<source.channels {
                    let channel = source.channel(c)
                    guard let frequency = tones.max(by: { tone(channel, frequency: $0, rate: source.rate) < tone(channel, frequency: $1, rate: source.rate) }) else { continue }
                    let reference = tone(channel, frequency: frequency, rate: source.rate)
                    guard reference > 0.001 else { continue }
                    let l = tone(left, frequency: frequency, rate: source.rate) / reference
                    let r = tone(right, frequency: frequency, rate: source.rate) / reference
                    print(String(format: "      %@ source ch %d (%.0f Hz): to L %.3f, to R %.3f", label, c, frequency, l, r))
                }
            }
            if let rendered = decode(url, mix: mix, stereo: source.channels != 2) {
                if source.channels == 2, rendered.channels == 2 {
                    let n = min(rendered.samples.count, source.samples.count)
                    var worst: Float = 0
                    for i in 0..<n { worst = max(worst, abs(rendered.samples[i] - source.samples[i])) }
                    if worst != 0 { allExact = false }
                    let l = source.channel(0), r = source.channel(1), rl = rendered.channel(0), rr = rendered.channel(1)
                    print("   new path, offline render through the listening tap: " + (worst == 0 ? "BIT-EXACT" : String(format: "max difference %.3g", worst))
                        + String(format: "; level L %@ R %@", rms(l) > 0 ? dB(rms(rl) / rms(l)) : "silent", rms(r) > 0 ? dB(rms(rr) / rms(r)) : "silent"))
                    if rms(l) > 0.01, rms(r) < 1e-6 { print("      stereo separation (left-only signal): right channel " + (rms(rr) == 0 ? "digital silence" : dB(rms(rr) / rms(rl)))) }
                } else if rendered.channels == 2 {
                    print("   system fold-down to stereo (AVFoundation offline renderer, with the listening tap):")
                    gains(rendered, label: "system:")
                }
            }
            // 3. SameSofa 1.1.0's own fold-down of the same channels (before Apple's voice processing).
            if source.channels > 2 {
                print("   SameSofa 1.1.0 fold-down of the same channels (then Apple voice processing, not reproducible here):")
                gains(legacyDownmix(source), label: "1.1.0: ")
            }
            // 4. An independent decoder, for lossless stereo.
            if let ffmpeg = referenceFFmpeg, source.channels == 2 {
                let raw = FileManager.default.temporaryDirectory.appendingPathComponent("samesofa-measure-\(getpid()).f32")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = ["-v", "error", "-y", "-i", url.path, "-map", "0:a:0", "-f", "f32le", "-c:a", "pcm_f32le", raw.path]
                try? process.run()
                process.waitUntilExit()
                if let data = try? Data(contentsOf: raw) {
                    let other = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    let n = min(other.count, source.samples.count)
                    var worst: Float = 0
                    for i in 0..<n { worst = max(worst, abs(other[i] - source.samples[i])) }
                    print(String(format: "   decoded source vs FFmpeg's decoder: max difference %.3g over %d samples", worst, n))
                }
                try? FileManager.default.removeItem(at: raw)
            }
        }
        print(allExact ? "RESULT new path bit-exact on all files" : "RESULT not bit-exact on every file (see above)")
        exit(0)
    }
}
