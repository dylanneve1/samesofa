import AVFoundation
import CoreAudio
import CWebRTCAudioDevice
import Foundation
import os
import SameSofaCore
import SameSofaKit
import WebRTC

// The call's audio without a call (no partner, no network, nothing audible):
//
//   samesofa-itest --audio-thread-test 1
//       No hardware at all. The output's and the microphone's audio threads run flat out
//       against each other while a third thread starts and ends "calls": the microphone
//       must never reach the speaker buffer (or the other way round), and nothing may crash.
//       Then the microphone converter at 8-192 kHz with 1-6 channels.
//
//   samesofa-itest --audio-engine-test film.mp4 [--real-output-switch 1]
//       The real engine at zero volume: a start that fails is tried again, the film's echo
//       reference never falls behind the clock, and (opt-in) the default sound output really
//       changes under a running film and call.

enum AudioThreadTests {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !ok { failures += 1 }
    }

    static func finish(_ what: String) -> Never {
        print("SUMMARY \(failures == 0 ? "all \(what) checks passed" : "\(failures) \(what) checks FAILED")")
        exit(failures == 0 ? 0 : 1)
    }

    /// Stands in for WebRTC: plays a constant, and looks at what the microphone path delivers.
    final class FakeCall: NSObject, RTCAudioDeviceDelegate {
        static let voiceSample: Int16 = 8192
        let state = OSAllocatedUnfairLock(initialState: State())

        struct State {
            var delivered = 0
            var foreign = 0
            var expected: Int16?
            var collected: [Int16] = []
            var collect = false
        }

        lazy var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock = { [state] _, _, _, frames, data, _, _ in
            guard let samples = data?.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) else { return noErr }
            state.withLock { s in
                s.delivered += Int(frames)
                if let expected = s.expected {
                    for i in 0..<Int(frames) where samples[i] != expected { s.foreign += 1 }
                }
                if s.collect { s.collected.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(frames))) }
            }
            return noErr
        }

        lazy var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock = { _, _, _, frames, data in
            guard let samples = data.pointee.mBuffers.mData?.assumingMemoryBound(to: Int16.self) else { return noErr }
            for i in 0..<Int(frames) { samples[i] = FakeCall.voiceSample }
            return noErr
        }

        var preferredInputSampleRate: Double { 48_000 }
        var preferredInputIOBufferDuration: TimeInterval { 0.01 }
        var preferredOutputSampleRate: Double { 48_000 }
        var preferredOutputIOBufferDuration: TimeInterval { 0.01 }
        func notifyAudioInputParametersChange() {}
        func notifyAudioOutputParametersChange() {}
        func notifyAudioInputInterrupted() {}
        func notifyAudioOutputInterrupted() {}
        func dispatchAsync(_ block: @escaping () -> Void) { DispatchQueue.global().async(execute: block) }
        func dispatchSync(_ block: @escaping () -> Void) { block() }
    }

    static func floatFormat(rate: Double, channels: Int, interleaved: Bool) -> AudioStreamBasicDescription {
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian
        if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        let bytes = UInt32(interleaved ? 4 * channels : 4)
        return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags, mBytesPerPacket: bytes,
                                           mFramesPerPacket: 1, mBytesPerFrame: bytes, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    /// Calls `body` with an AudioBufferList of `frames` frames whose samples come from `sample(channel, frame)`.
    static func withBuffers(frames: Int, channels: Int, interleaved: Bool, sample: (Int, Int) -> Float, _ body: (UnsafePointer<AudioBufferList>) -> Void) {
        let bufferCount = interleaved ? 1 : channels
        let list = AudioBufferList.allocate(maximumBuffers: bufferCount)
        defer { free(list.unsafeMutablePointer) }
        var storage: [UnsafeMutablePointer<Float>] = []
        for b in 0..<bufferCount {
            let perBuffer = interleaved ? channels : 1
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * perBuffer)
            for f in 0..<frames {
                if interleaved { for c in 0..<channels { data[f * channels + c] = sample(c, f) } } else { data[f] = sample(b, f) }
            }
            list[b] = AudioBuffer(mNumberChannels: UInt32(perBuffer), mDataByteSize: UInt32(frames * perBuffer * 4), mData: UnsafeMutableRawPointer(data))
            storage.append(data)
        }
        body(UnsafePointer(list.unsafeMutablePointer))
        storage.forEach { $0.deallocate() }
    }

    // MARK: Threads

    static func runThreadTest() -> Never {
        let hub = AudioHub(mode: .live)
        let call = FakeCall()
        _ = hub.initialize(with: call)
        hub.setCallStateForTesting(playing: true, recording: true)
        do { try hub.prepareCaptureForTesting(format: floatFormat(rate: 48_000, channels: 1, interleaved: false), cancelEcho: false) } catch {
            check("microphone path set up", false, "\(error)")
            finish("audio thread")
        }
        let microphoneSample: Float = -0.5 // arrives at WebRTC as -16384
        call.state.withLock { $0.expected = -16384 }
        let voice = Float(FakeCall.voiceSample) / 32768
        let stop = AtomicFlag()
        let speakerForeign = OSAllocatedUnfairLock(initialState: 0), rendered = OSAllocatedUnfairLock(initialState: 0)
        let group = DispatchGroup()

        // The output's audio thread.
        let renderThread = Thread {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
            var foreign = 0, count = 0
            while !stop.isSet {
                hub.renderForTesting(frames: 512, into: buffer)
                // Either the voice, or silence (no call at that instant): never anything else.
                for i in 0..<512 where buffer[i] != voice && buffer[i] != 0 { foreign += 1 }
                count += 1
            }
            buffer.deallocate()
            let foreignTotal = foreign, countTotal = count
            speakerForeign.withLock { $0 = foreignTotal }
            rendered.withLock { $0 = countTotal }
            group.leave()
        }
        // The microphone's audio thread.
        let captureThread = Thread {
            withBuffers(frames: 480, channels: 1, interleaved: false, sample: { _, _ in microphoneSample }) { buffers in
                while !stop.isSet { hub.captureForTesting(buffers, frames: 480) }
            }
            group.leave()
        }
        group.enter(); group.enter()
        renderThread.start(); captureThread.start()
        Thread.sleep(forTimeInterval: 3)
        let steady = call.state.withLock { ($0.delivered, $0.foreign) }

        // Calls starting and ending while both audio threads run.
        var cycles = 0
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            _ = hub.terminateDevice()
            _ = hub.initialize(with: call)
            hub.setCallStateForTesting(playing: true, recording: true)
            cycles += 1
        }
        Thread.sleep(forTimeInterval: 0.2)
        stop.set()
        group.wait()
        let total = call.state.withLock { ($0.delivered, $0.foreign) }
        let speaker = speakerForeign.withLock { $0 }, buffers = rendered.withLock { $0 }
        check("both audio threads ran flat out", buffers > 10_000 && steady.0 > 480_000, "\(buffers) output buffers, \(steady.0) microphone frames in 3 s")
        check("the microphone never reaches the speaker buffer", speaker == 0, "\(speaker) foreign samples in \(buffers * 512)")
        check("the voice never reaches the microphone signal", total.1 == 0, "\(total.1) foreign samples in \(total.0)")
        check("calls starting and ending under running audio threads", cycles > 1000 && total.0 > steady.0, "\(cycles) start/stop cycles, no crash")
        _ = hub.terminateDevice()

        // The microphone converter: every rate and channel count a device may have.
        let rates: [Double] = [8000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000, 192_000]
        var worst = "", combinations = 0
        for rate in rates {
            for channels in [1, 2, 3, 4, 6] {
                for interleaved in [false, true] {
                    for toneOnAllChannels in [true, false] where channels > 1 || toneOnAllChannels {
                        let blocks = [Int(rate / 100), 512, 137, 1024]
                        let block = blocks[combinations % blocks.count]
                        combinations += 1
                        if let problem = convertOne(hub: hub, call: call, rate: rate, channels: channels, interleaved: interleaved,
                                                    block: block, toneOnAllChannels: toneOnAllChannels) {
                            worst += "\n      \(Int(rate)) Hz, \(channels) ch, \(interleaved ? "interleaved" : "planar"), blocks of \(block), tone on \(toneOnAllChannels ? "all" : "last"): \(problem)"
                        }
                    }
                }
            }
        }
        check("microphone converter: 1 kHz tone arrives intact at 48 kHz mono from every format", worst.isEmpty,
              "\(combinations) combinations of 8-192 kHz, 1-6 channels, planar/interleaved, four block sizes\(worst)")
        // A format that cannot be used is refused, not crashed on.
        var bad = floatFormat(rate: 48_000, channels: 1, interleaved: false)
        bad.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        bad.mBitsPerChannel = 16
        var refused = false
        do { try hub.prepareCaptureForTesting(format: bad, cancelEcho: false) } catch { refused = true }
        check("a microphone format that cannot be used is refused", refused)
        // A buffer list that does not hold what it claims (a device going away) is skipped.
        do {
            try hub.prepareCaptureForTesting(format: floatFormat(rate: 48_000, channels: 3, interleaved: false), cancelEcho: true)
            _ = hub.initialize(with: call)
            hub.setCallStateForTesting(playing: true, recording: true)
            let before = call.state.withLock { $0.delivered }
            withBuffers(frames: 480, channels: 2, interleaved: false, sample: { _, _ in 0.1 }) { hub.captureForTesting($0, frames: 480) }
            var empty = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
            hub.captureForTesting(&empty, frames: 480)
            check("buffers that do not match the format are skipped", call.state.withLock { $0.delivered } == before)
            // And with the canceller in place a normal buffer goes through.
            withBuffers(frames: 480, channels: 3, interleaved: false, sample: { _, _ in 0.1 }) { hub.captureForTesting($0, frames: 480) }
            check("three-channel microphone through the echo canceller", call.state.withLock { $0.delivered } == before + 480)
        } catch { check("three-channel microphone set up", false, "\(error)") }
        hub.stop()
        finish("audio thread")
    }

    /// Two seconds of a 1 kHz tone through the microphone path; nil if it arrives intact.
    static func convertOne(hub: AudioHub, call: FakeCall, rate: Double, channels: Int, interleaved: Bool, block: Int, toneOnAllChannels: Bool) -> String? {
        do { try hub.prepareCaptureForTesting(format: floatFormat(rate: rate, channels: channels, interleaved: interleaved), cancelEcho: false) } catch { return "refused: \(error)" }
        _ = hub.initialize(with: call)
        hub.setCallStateForTesting(playing: true, recording: true)
        call.state.withLock { $0.expected = nil; $0.collected = []; $0.collect = true }
        let total = Int(rate * 2)
        var position = 0
        while position < total {
            let frames = min(block, total - position)
            let start = position
            withBuffers(frames: frames, channels: channels, interleaved: interleaved, sample: { channel, frame in
                toneOnAllChannels || channel == channels - 1 ? Float(0.5 * sin(2 * Double.pi * 1000 * Double(start + frame) / rate)) : 0
            }) { hub.captureForTesting($0, frames: frames) }
            position += frames
        }
        let out = call.state.withLock { s -> [Int16] in s.collect = false; return s.collected }
        // Length: two seconds, less what is still inside the converter and the 10 ms queue.
        guard out.count > 96_000 - 4800, out.count <= 96_000 else { return "\(out.count) frames out, expected about 96000" }
        let middle = Array(out[24_000..<72_000])
        var crossings = 0, peak = 0, largestStep = 0
        for i in 1..<middle.count {
            if middle[i - 1] < 0, middle[i] >= 0 { crossings += 1 }
            peak = max(peak, abs(Int(middle[i])))
            largestStep = max(largestStep, abs(Int(middle[i]) - Int(middle[i - 1])))
        }
        let expectedPeak = 16_384.0 / (toneOnAllChannels ? 1 : Double(channels))
        if abs(crossings - 1000) > 1 { return "\(crossings) cycles in one second, expected 1000" }
        if abs(Double(peak) - expectedPeak) > expectedPeak * 0.04 + 2 { return "peak \(peak), expected \(Int(expectedPeak))" }
        // A dropped or repeated stretch shows as a jump larger than the tone ever makes.
        let steepest = expectedPeak * 2 * Double.pi * 1000 / 48_000
        if Double(largestStep) > steepest * 1.15 + 3 { return "a jump of \(largestStep) between two samples (tone: at most \(Int(steepest)))" }
        return nil
    }

    final class AtomicFlag: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        var isSet: Bool { lock.withLock { $0 } }
        func set() { lock.withLock { $0 = true } }
    }
}
