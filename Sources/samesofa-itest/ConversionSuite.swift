// Conversion end-to-end test: for each film (MKV, AVI, WebM, ...), a host
// converts it with the FFmpeg helper while the room is already open, the
// guest receives the MP4 over the data channel, and both play it in sync.
// Also checks audio reaches both sides' audio engines, that the guest's copy
// is byte-identical to what the host converted, and that audio/video sync
// survived conversion (the test films flash and beep together every 3 s,
// see scripts/dev/make-test-films.sh).
//
// Usage: samesofa-itest --server ws://127.0.0.1:18787 --convert-suite a.mkv,b.avi,...

import AVFoundation
import CryptoKit
import Foundation
import SameSofaCore
import SameSofaKit

final class ConversionSuite {
    struct Expectation {
        var remuxOnly: Bool
        var videoEncoded = false
        var audioEncoded = false
        var subtitles = false
        var audioStream: Int?
    }

    /// What the planner should decide for the generated test films.
    static let expectations: [String: Expectation] = [
        "h264-aac.mkv": .init(remuxOnly: true),
        "hevc10-ac3.mkv": .init(remuxOnly: true),
        "vp9-opus.mkv": .init(remuxOnly: false, videoEncoded: true, audioEncoded: true),
        "xvid-mp3.avi": .init(remuxOnly: false, videoEncoded: true, audioEncoded: true),
        "h264-mp3.avi": .init(remuxOnly: false, videoEncoded: false, audioEncoded: true, subtitles: true),
        "two-audio-srt.mkv": .init(remuxOnly: true, subtitles: true, audioStream: 2),
    ]

    let server: URL
    let start = Date()
    var results: [(String, Bool, String)] = []
    var failed = false
    var timings: [String] = []

    /// A full FFmpeg (e.g. Homebrew's, with signalstats/silencedetect) used only to
    /// measure where the flashes and beeps are in the source film, as FFmpeg-based
    /// players show it. Without it the ideal times (1, 4, 7, ... s) are assumed.
    let referenceFFmpeg: String?

    init(server: URL, referenceFFmpeg: String?) {
        self.server = server
        self.referenceFFmpeg = referenceFFmpeg
    }

    func log(_ s: String) { print(String(format: "[%7.2f] ", Date().timeIntervalSince(start)) + s) }

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        results.append((name, ok, detail))
        log("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
        if !ok { failed = true }
    }

    @discardableResult
    func wait(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func spin(_ seconds: Double) { wait(seconds) { false } }

    func settings(_ label: String, hue: Double) -> PartySettings {
        PartySettings(serverURL: server, ice: IceSettings(stunURLs: []), audioMode: .synthetic, camera: .synthetic(label: label, hue: hue))
    }

    func inspect(_ film: URL) -> Result<FilmCheck, Error>? {
        var outcome: Result<FilmCheck, Error>?
        Task {
            do { outcome = .success(try await FilmPreparer.inspect(film)) } catch { outcome = .failure(error) }
        }
        wait(60) { outcome != nil }
        return outcome
    }

    func run(films: [URL]) -> Never {
        guard FFmpegTools.locate() != nil else {
            check("FFmpeg helper found (run scripts/build-ffmpeg.sh)", false)
            finish()
        }
        FilmPreparer.removeLeftovers()
        if let transcode = films.first(where: { Self.expectations[$0.lastPathComponent]?.videoEncoded == true }) {
            cancellation(transcode)
        }
        for film in films { runOne(film) }
        log("TIMINGS")
        timings.forEach { log("  " + $0) }
        finish()
    }

    func finish() -> Never {
        let passed = results.filter { $0.1 }.count
        log("SUMMARY \(passed)/\(results.count) checks passed")
        exit(failed ? 1 : 0)
    }

    /// Leaving while the film is still converting stops ffmpeg and deletes the partial file.
    func cancellation(_ film: URL) {
        log("== cancel while converting: \(film.lastPathComponent)")
        guard case .success(let filmCheck)? = inspect(film), case .convert = filmCheck else {
            check("cancel: film needs converting", false)
            return
        }
        let host = Party(role: .host, settings: settings("Host", hue: 0.62))
        do { try host.host(film: film, check: filmCheck) } catch { check("cancel: host starts", false, "\(error)"); return }
        wait(10) { (host.preparing?.fraction ?? 0) > 0.05 }
        let partial = (try? FileManager.default.contentsOfDirectory(atPath: FilmPreparer.directory.path)) ?? []
        check("cancel: conversion was running", host.preparing != nil && !partial.isEmpty,
              String(format: "%.0f%%, %d file(s)", (host.preparing?.fraction ?? 0) * 100, partial.count))
        host.leave()
        let gone = wait(5) { ((try? FileManager.default.contentsOfDirectory(atPath: FilmPreparer.directory.path)) ?? []).isEmpty }
        check("cancel: partial file deleted", gone)
    }

    func runOne(_ film: URL) {
        let name = film.lastPathComponent
        log("== \(name)")
        let expect = Self.expectations[name]
        let t0 = Date()
        guard let outcome = inspect(film), case .success(let filmCheck) = outcome else {
            check("\(name): inspected", false, "\(String(describing: inspect(film)))")
            return
        }
        guard case .convert(let plan, _) = filmCheck else {
            check("\(name): needs converting", false, "shared as is")
            return
        }
        log("plan: \(plan.notes.joined(separator: "; "))")
        if let expect {
            check("\(name): \(expect.remuxOnly ? "remux only" : "transcode")", plan.isRemuxOnly == expect.remuxOnly &&
                  plan.reencodesVideo == expect.videoEncoded && plan.reencodesAudio == expect.audioEncoded,
                  "video \(plan.reencodesVideo ? "encode" : "copy"), audio \(plan.reencodesAudio ? "encode" : "copy")")
            check("\(name): subtitles \(expect.subtitles ? "carried" : "none")", (plan.subtitles != nil) == expect.subtitles,
                  "\(String(describing: plan.subtitles))")
            if let stream = expect.audioStream {
                check("\(name): default audio track chosen", plan.audio?.stream == stream, "stream \(plan.audio?.stream ?? -1)")
            }
        }

        let host = Party(role: .host, settings: settings("Host", hue: 0.62))
        let guest = Party(role: .guest, settings: settings("Guest", hue: 0.05))
        guest.playback.testClockSkew = 321.123
        defer {
            guest.leave()
            host.leave()
            spin(1)
        }
        do { try host.host(film: film, check: filmCheck) } catch {
            check("\(name): host starts", false, "\(error)")
            return
        }
        var code = ""
        let gotCode = wait(10) {
            if case .waitingForPartner(let c) = host.phase { code = c; return true }
            return false
        }
        let convertingWhenCodeShown = host.preparing != nil
        check("\(name): room open", gotCode, convertingWhenCodeShown ? "(code shown while converting)" : "(conversion already done)")
        guest.join(code: code)
        check("\(name): both connected", wait(20) { host.phase == .together && guest.phase == .together })
        var guestSawPreparing = false
        let converted = wait(900) {
            if guest.preparing != nil { guestSawPreparing = true }
            if case .ended = host.phase { return true }
            return host.preparing == nil && host.sharedFile != nil
        }
        let took = Date().timeIntervalSince(t0)
        check("\(name): converted", converted, String(format: "%.1f s for %.0f s of film (%.1fx real time)%@", took, plan.duration,
                                                      plan.duration / max(took, 0.001), guestSawPreparing ? ", guest saw progress" : ""))
        guard converted, let shared = host.sharedFile else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: shared.path)[.size]) as? NSNumber)?.int64Value ?? 0
        timings.append(String(format: "%@: %@ %.1f s (%.1fx), %.1f MB -> %.1f MB", name, plan.isRemuxOnly ? "remux" : "transcode", took,
                              plan.duration / max(took, 0.001), Double(fileSize(film)) / 1e6, Double(size) / 1e6))
        check("\(name): guest player ready", wait(60) { guest.playback.isLoaded && !guest.playback.localBuffering && guest.playback.duration > 0 },
              String(format: "duration %.2f (source %.2f)", guest.playback.duration, plan.duration))
        check("\(name): duration kept", abs(guest.playback.duration - plan.duration) < 0.5 && abs(host.playback.duration - guest.playback.duration) < 0.05)
        check("\(name): clock sync", wait(5) { abs(guest.playback.clockOffset + 321.123) < 0.005 })
        if expect?.subtitles == true {
            let both = wait(5) { host.playback.hasSubtitles && guest.playback.hasSubtitles }
            guest.playback.setSubtitles(true)
            check("\(name): subtitle track on both, toggles on", both && guest.playback.subtitlesOn && guest.playback.selectedSubtitle != nil)
            guest.playback.setSubtitles(false)
            check("\(name): subtitles toggle off", !guest.playback.subtitlesOn && guest.playback.selectedSubtitle == nil)
        }

        func drift() -> Double { abs(host.playback.currentTime - guest.playback.currentTime) }
        var hostLevel: Float = 0, guestLevel: Float = 0
        func sampleLevels() {
            hostLevel = max(hostLevel, host.hub.filmLevel)
            guestLevel = max(guestLevel, guest.hub.filmLevel)
        }
        func spinSampling(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { spin(0.1); sampleLevels() }
        }
        let duration = guest.playback.duration

        guest.playback.play()
        spinSampling(3)
        check("\(name): play from guest starts both", host.playback.player.rate > 0 && guest.playback.player.rate > 0 && drift() < 0.25,
              String(format: "host %.2f guest %.2f", host.playback.currentTime, guest.playback.currentTime))
        host.playback.pause()
        spin(1.5)
        check("\(name): pause from host stops both", host.playback.player.rate == 0 && guest.playback.player.rate == 0 && drift() < 0.1,
              String(format: "host %.3f guest %.3f", host.playback.currentTime, guest.playback.currentTime))
        let target = duration * 0.5
        guest.playback.seek(to: target)
        spin(2)
        check("\(name): seek from guest moves host", abs(host.playback.currentTime - target) < 0.2 && abs(guest.playback.currentTime - target) < 0.2,
              String(format: "host %.2f guest %.2f", host.playback.currentTime, guest.playback.currentTime))
        host.playback.play()
        spinSampling(3)
        let back = duration * 0.25
        host.playback.seek(to: back)
        spinSampling(3)
        check("\(name): seek while playing from host", abs(host.playback.currentTime - (back + 3)) < 0.6 && drift() < 0.25,
              String(format: "host %.2f guest %.2f", host.playback.currentTime, guest.playback.currentTime))
        guest.playback.pause()
        spin(1)
        check("\(name): pause from guest stops host", host.playback.player.rate == 0)
        guest.playback.play()
        spinSampling(2)
        check("\(name): play from guest resumes host", host.playback.player.rate > 0)
        var worst = 0.0
        let soakEnd = Date().addingTimeInterval(10)
        while Date() < soakEnd {
            spin(0.5)
            sampleLevels()
            if host.playback.currentTime > duration - 3 { break }
            worst = max(worst, drift())
        }
        check("\(name): drift under 0.25 s while playing", worst < 0.25, String(format: "max %.3f s", worst))
        check("\(name): film audio playing on both sides", hostLevel > 0.02 && guestLevel > 0.02,
              String(format: "peak host %.2f guest %.2f", hostLevel, guestLevel))
        host.playback.pause()

        check("\(name): transfer completes", wait(120) { guest.receiver?.isComplete == true })
        guard let received = guest.receiver?.cacheURL else { return }
        check("\(name): guest copy identical to converted film", sha256(shared) == sha256(received))
        let sync = AVSyncProbe.measure(received)
        let ideal = stride(from: 1.0, to: duration - 0.5, by: 3.0).map { $0 }
        var source = AVSyncProbe.Result(flashes: ideal, beeps: ideal)
        var tolerance = (picture: 0.045, sound: 0.03, sync: 0.045)
        if let referenceFFmpeg, let video = plan.video?.stream, let audio = plan.audio?.stream {
            source = AVSyncProbe.reference(ffmpeg: referenceFFmpeg, film: film, videoStream: video, audioStream: audio)
            tolerance = (picture: 0.005, sound: 0.012, sync: 0.02)
            if plan.regenerateTimestamps {
                // AVI stores no presentation times, so with B-frames the picture's
                // timing is ambiguous by the reorder delay and players disagree by
                // up to a frame (FFmpeg itself shows these test AVIs 1-2 frames late).
                tolerance.picture = 0.045
                tolerance.sync = 0.045
            }
        }
        func nearest(_ t: Double, _ list: [Double]) -> Double { list.map { $0 - t }.min { abs($0) < abs($1) } ?? 99 }
        let flashOff = sync.flashes.map { abs(nearest($0, source.flashes)) }.max() ?? 99
        let beepOff = sync.beeps.map { abs(nearest($0, source.beeps)) }.max() ?? 99
        // Audio minus video at each event, after conversion and in the source.
        let outPairs = sync.flashes.map { nearest($0, sync.beeps) }
        let srcPairs = source.flashes.map { nearest($0, source.beeps) }
        let srcMean = srcPairs.reduce(0, +) / Double(max(srcPairs.count, 1))
        let worstPair = outPairs.map { abs($0 - srcMean) }.max() ?? 99
        let idealMean = outPairs.reduce(0, +) / Double(max(outPairs.count, 1))
        check("\(name): flashes and beeps found", sync.flashes.count >= ideal.count - 1 && sync.beeps.count >= ideal.count - 1,
              "\(sync.flashes.count) flashes, \(sync.beeps.count) beeps, \(ideal.count) expected (source: \(source.flashes.count)/\(source.beeps.count))")
        check("\(name): picture on the source's timeline", flashOff <= tolerance.picture, String(format: "worst flash %.1f ms off", flashOff * 1000))
        check("\(name): sound on the source's timeline", beepOff <= tolerance.sound, String(format: "worst beep %.1f ms off", beepOff * 1000))
        check("\(name): audio/video sync kept", worstPair <= tolerance.sync,
              String(format: "beep - flash after conversion: mean %+.1f ms (source %+.1f ms), worst deviation %.1f ms%@",
                     outPairs.reduce(0, +) / Double(max(outPairs.count, 1)) * 1000, srcMean * 1000, worstPair * 1000,
                     referenceFFmpeg == nil ? ", no reference FFmpeg: ideal times assumed" : ""))
        log(String(format: "   (the test film was made with flash and beep at the same instant; after conversion audio - video = %+.1f ms)", idealMean * 1000))
        guest.leave()
        host.leave()
        check("\(name): converted file removed after leaving", !FileManager.default.fileExists(atPath: shared.path))
    }

    func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    func sha256(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "unreadable \(url.lastPathComponent)" }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Finds the white flashes and the beeps in a film with AVFoundation (the
/// same decoders AVPlayer uses), on the film's own timeline.
enum AVSyncProbe {
    struct Result {
        var flashes: [Double] = []
        var beeps: [Double] = []
    }

    static func measure(_ url: URL) -> Result {
        var result = Result()
        let asset = AVURLAsset(url: url)
        let group = DispatchGroup()
        group.enter()
        Task {
            defer { group.leave() }
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                result.flashes = (try? flashes(asset, track)) ?? []
            }
            if let track = try? await asset.loadTracks(withMediaType: .audio).first {
                result.beeps = (try? beeps(asset, track)) ?? []
            }
        }
        while group.wait(timeout: .now() + 0.02) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return result
    }

    /// The same measurements on the source film, decoded by a full FFmpeg.
    static func reference(ffmpeg: String, film: URL, videoStream: Int, audioStream: Int) -> Result {
        func run(_ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-hide_banner", "-nostdin", "-i", film.path] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            guard (try? p.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        var result = Result()
        // signalstats prints "frame:N pts:... pts_time:T" then "lavfi.signalstats.YAVG=Y".
        let video = run(["-map", "0:\(videoStream)", "-vf", "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-", "-f", "null", "-"])
        var time: Double?
        var frames: [(Double, Double)] = []
        for line in video.split(separator: "\n") {
            if let r = line.range(of: "pts_time:") {
                time = Double(line[r.upperBound...].split(separator: " ").first ?? "")
            } else if let r = line.range(of: "YAVG="), let y = Double(line[r.upperBound...]), let t = time {
                frames.append((t, y))
            }
        }
        // YAVG is in the source's bit depth (0-255, 0-1023, ...): compare with the brightest frame.
        let threshold = (frames.map(\.1).max() ?? 0) * 0.9
        var wasBright = false
        for (t, y) in frames {
            let bright = y > threshold
            if bright && !wasBright { result.flashes.append(t) }
            wasBright = bright
        }
        let audio = run(["-map", "0:\(audioStream)", "-af", "silencedetect=n=-12dB:d=0.3", "-f", "null", "-"])
        for line in audio.split(separator: "\n") {
            if let r = line.range(of: "silence_end: "), let t = Double(line[r.upperBound...].split(separator: " ").first ?? "") {
                result.beeps.append(t)
            }
        }
        return result
    }

    static func flashes(_ asset: AVAsset, _ track: AVAssetTrack) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        reader.add(output)
        reader.startReading()
        var times: [Double] = []
        var wasBright = false
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            CVPixelBufferLockBaseAddress(image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { continue }
            let width = CVPixelBufferGetWidthOfPlane(image, 0), height = CVPixelBufferGetHeightOfPlane(image, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var sum = 0, count = 0
            for y in Swift.stride(from: 0, to: height, by: 8) {
                for x in Swift.stride(from: 0, to: width, by: 8) { sum += Int(bytes[y * stride + x]); count += 1 }
            }
            let luma = Double(sum) / Double(max(count, 1)) / 255
            let bright = luma > 0.85
            if bright && !wasBright { times.append(t) }
            wasBright = bright
        }
        return times
    }

    static func beeps(_ asset: AVAsset, _ track: AVAssetTrack) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var onsets: [Double] = []
        var lastLoud = -10.0
        while let sample = output.copyNextSampleBuffer() {
            guard let format = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let channels = Int(asbd.mChannelsPerFrame), rate = asbd.mSampleRate
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let length = CMBlockBufferGetDataLength(block)
            guard channels > 0, length > 0 else { continue }
            var floats = [Float](repeating: 0, count: length / 4)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: floats.count * 4, destination: &floats) == noErr else { continue }
            let frames = floats.count / channels
            for i in 0..<frames {
                var peak: Float = 0
                for c in 0..<channels { peak = max(peak, abs(floats[i * channels + c])) }
                guard peak > 0.3 else { continue }
                let t = start + Double(i) / rate
                if t - lastLoud > 0.5 { onsets.append(t) }
                lastLoud = t
            }
        }
        return onsets
    }
}
