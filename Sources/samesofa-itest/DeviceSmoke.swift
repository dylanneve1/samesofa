import AVFoundation
import CoreMedia
import Foundation
import SameSofaCore
import SameSofaKit

// A quick check of this Mac's real sound devices with the call's audio engine:
//
//   samesofa-itest --device-smoke 1 [--seconds 6] [--include-bluetooth 1] [--real-default-switch 1]
//
// No partner, no camera, no network. Nothing is played: the engine's output
// carries digital silence at zero volume. The microphone is opened (macOS
// shows its orange dot, and asks once whether the terminal may use it), what
// it records is measured and thrown away.
//
// The engine is started the way WebRTC starts it in a call. It then runs for
// a few seconds with the echo canceller fed a silent reference, is rebuilt
// as after a device change, and every other microphone is opened in turn
// (Bluetooth ones only on request: opening a headset's microphone switches
// the headset to call quality while it is open). With --real-default-switch
// the system's default microphone is really changed and put back.
//
// Exit status 0: everything that could be tested works (a Mac without a
// microphone passes: there is nothing to test). 1: something is wrong.

enum DeviceSmoke {
    static var rows: [(String, String)] = []
    static var problems: [String] = []

    static func row(_ name: String, _ value: String) { rows.append((name, value)) }

    static func decibels(_ peak: Double) -> String {
        peak <= 0 ? "digital silence" : String(format: "%.1f dBFS", 20 * log10(peak))
    }

    static var restore: (() -> Void)?

    static func run(_ args: [String: String]) -> Never {
        let seconds = max(2, Double(args["seconds"] ?? "6") ?? 6)
        let includeBluetooth = args["include-bluetooth"] != nil
        let realSwitch = args["real-default-switch"] != nil
        print("SameSofa device smoke test: nothing is played, nothing is sent anywhere.")

        // 1. The devices, by kind (no names).
        if let output = AudioDevices.defaultOutput() {
            let route = OutputDevice.currentRoute()
            row("sound output", "\(output.summary) -> \(route.kind.rawValue)")
        } else {
            row("sound output", "none")
            problems.append("no sound output")
        }
        let inputs = AudioDevices.inputs()
        let defaultInput = AudioDevices.defaultInput(), preferred = AudioDevices.preferredInput()
        if let preferred {
            var text = preferred.summary
            if let defaultInput, defaultInput.id != preferred.id {
                text += "  (the default is \(defaultInput.summary); the built-in one is used so the headphones stay in full quality)"
            }
            row("microphone", text)
        } else {
            row("microphone", "no input device")
        }
        if inputs.count > 1 { row("all microphones", inputs.map(\.summary).joined(separator: " | ")) }

        // 2. Permission.
        var access = AVCaptureDevice.authorizationStatus(for: .audio)
        if preferred != nil, access == .notDetermined {
            print("Asking macOS for microphone access (answer the dialog) ...")
            var answered = false
            AVCaptureDevice.requestAccess(for: .audio) { _ in answered = true }
            let deadline = Date().addingTimeInterval(120)
            while !answered, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            access = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        if preferred != nil {
            switch access {
            case .authorized: row("microphone access", "allowed")
            case .denied, .restricted:
                row("microphone access", "NOT allowed for this terminal: System Settings > Privacy & Security > Microphone, then run again")
                problems.append("microphone access denied, the microphone could not be tested")
            default:
                row("microphone access", "not decided")
                problems.append("microphone access was not granted")
            }
        }

        // 3. The engine, started as in a call.
        let hub = AudioHub(mode: .live)
        hub.voiceVolume = 0
        hub.filmVolume = 0
        let call = AudioThreadTests.FakeCall()
        call.silent = true
        _ = hub.initialize(with: call)
        _ = hub.initializePlayout()
        _ = hub.initializeRecording()
        _ = hub.startPlayout()
        _ = hub.startRecording()
        // A film clock with no film sound: the film branch of the echo reference runs, on silence.
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: 60, preferredTimescale: 600))
            CMTimebaseSetRate(timebase, rate: 1)
            hub.setFilmClockForTesting(timebase)
        }

        struct Measurement {
            var running = false
            var error: String?
            var renderCallbacks = 0, captureCallbacks = 0
            var delivered = 0
            var capturedPeak = 0.0, sentPeak = 0.0
            var format: String?
            var device: String?
            var wiring: Bool?
            var voiceProcessingOff = true
            var state = MicrophoneState.notStarted
        }
        /// Lets the engine run for `duration` and reports what happened in that time.
        func measure(_ duration: Double) -> Measurement {
            AudioThreadTests.spin(0.4) // settle
            let before = hub.diagnostics()
            call.state.withLock { $0.delivered = 0; $0.peak = 0 }
            AudioThreadTests.spin(duration)
            let after = hub.diagnostics()
            let sent = call.state.withLock { ($0.delivered, $0.peak) }
            return Measurement(running: after.engineRunning, error: hub.engineError,
                               renderCallbacks: after.renderCallbacks - before.renderCallbacks,
                               captureCallbacks: after.captureCallbacks - before.captureCallbacks,
                               delivered: sent.0, capturedPeak: Double(after.capturedPeak), sentPeak: Double(sent.1) / 32768,
                               format: after.inputFormat, device: after.inputDevice, wiring: after.microphoneFeedsOnlyTheCanceller,
                               voiceProcessingOff: after.voiceProcessingOff, state: hub.microphoneState)
        }
        /// Judges a measurement of `duration` seconds; returns a short verdict and notes problems under `label`.
        func judge(_ m: Measurement, duration: Double, label: String, microphoneExpected: Bool) -> String {
            var faults: [String] = []
            if !m.running { faults.append("engine not running" + (m.error.map { " (\($0))" } ?? "")) }
            if m.renderCallbacks == 0 { faults.append("the output does not call back") }
            if microphoneExpected {
                if m.state != .working { faults.append("microphone \(m.state)") }
                if m.captureCallbacks == 0 { faults.append("the microphone does not call back") }
                let expected = duration * 48_000
                if Double(m.delivered) < expected * 0.9 || Double(m.delivered) > expected * 1.1 {
                    faults.append(String(format: "%d frames reached the call in %.1f s, expected about %.0f", m.delivered, duration, expected))
                }
                if m.capturedPeak == 0, m.captureCallbacks > 0 { faults.append("the microphone delivers digital silence (muted, or blocked by macOS?)") }
                if m.wiring == false { faults.append("the microphone is connected to something other than the echo canceller") }
            }
            if !m.voiceProcessingOff { faults.append("Apple's voice processing is on") }
            for fault in faults { problems.append("\(label): \(fault)") }
            guard faults.isEmpty else { return "FAILED: " + faults.joined(separator: "; ") }
            guard microphoneExpected else { return "ok (output only)" }
            return String(format: "ok: %@ -> 48000 Hz mono, %d microphone callbacks, level %@ at the microphone, %@ after clean-up",
                          m.format ?? "?", m.captureCallbacks, decibels(m.capturedPeak), decibels(m.sentPeak))
        }

        let microphoneExpected = preferred != nil && access == .authorized
        let first = measure(seconds)
        row("call audio engine", first.running ? "running" : "NOT running" + (first.error.map { ": \($0)" } ?? ""))
        row("output callbacks", "\(first.renderCallbacks) in \(String(format: "%.0f", seconds)) s")
        if preferred == nil {
            row("microphone test", "no input device: nothing to test")
            _ = judge(first, duration: seconds, label: "engine", microphoneExpected: false)
        } else {
            row("microphone (\(first.device ?? preferred!.transport.rawValue))", judge(first, duration: seconds, label: "microphone", microphoneExpected: microphoneExpected))
            if microphoneExpected {
                row("microphone wiring", first.wiring == true ? "to the echo canceller only (never to the speakers); Apple voice processing off" : "WRONG")
            }
        }
        row("echo reference", "ran on silence (voice and film), film trim \(Int(hub.filmReferenceTrim * 1000)) ms")

        // 4. As after a device change: the engine is rebuilt.
        let restarts = hub.engineRestarts
        hub.simulateDeviceChange()
        let rebuilt = measure(2)
        row("device change (simulated)", hub.engineRestarts > restarts ? judge(rebuilt, duration: 2, label: "after a device change", microphoneExpected: microphoneExpected)
            : "FAILED: the engine was not rebuilt")
        if hub.engineRestarts == restarts { problems.append("the engine was not rebuilt after a device change") }

        // 5. Every other microphone, opened by this process only (the system's default stays as it is).
        if microphoneExpected {
            for input in inputs where input.id != preferred?.id {
                if input.transport == .bluetooth, !includeBluetooth {
                    row("other microphone (\(input.summary))", "skipped: opening a Bluetooth microphone switches the headphones to call quality (--include-bluetooth 1 to test it)")
                    continue
                }
                hub.inputDeviceForTesting = input.id
                hub.simulateDeviceChange()
                let m = measure(2)
                row("other microphone (\(input.summary))", judge(m, duration: 2, label: "microphone \(input.summary)", microphoneExpected: true))
            }
            hub.inputDeviceForTesting = nil
            hub.simulateDeviceChange()
        }

        // 6. On request: really change the system's default microphone, and put it back.
        if realSwitch, microphoneExpected, let original = defaultInput,
           let other = inputs.first(where: { $0.id != original.id && (includeBluetooth || $0.transport != .bluetooth) }) {
            restore = { AudioDevices.setDefault(original.id, input: true) }
            atexit { DeviceSmoke.restore?() }
            for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig) { _ in DeviceSmoke.restore?(); _exit(1) } }
            let before = hub.engineRestarts
            AudioDevices.setDefault(other.id, input: true)
            let switched = measure(3)
            row("default microphone changed (\(other.summary))", hub.engineRestarts > before
                ? judge(switched, duration: 3, label: "after changing the default microphone", microphoneExpected: true)
                : "FAILED: the engine did not notice")
            if hub.engineRestarts == before { problems.append("the engine did not notice the new default microphone") }
            AudioDevices.setDefault(original.id, input: true)
            let back = measure(3)
            row("default microphone restored", AudioDevices.defaultInput()?.id == original.id
                ? judge(back, duration: 3, label: "after restoring the default microphone", microphoneExpected: true) : "FAILED: could not restore it")
            if AudioDevices.defaultInput()?.id != original.id { problems.append("the default microphone could not be restored") }
            restore = nil
        } else if realSwitch {
            row("default microphone change", "not possible: it needs a second microphone" + (includeBluetooth ? "" : " that is not Bluetooth"))
        } else if inputs.count > 1 {
            row("default microphone change", "not done (--real-default-switch 1 changes the system's default microphone for a few seconds and puts it back)")
        }
        _ = hub.stopPlayout()
        _ = hub.stopRecording()
        _ = hub.terminateDevice()
        hub.stop()

        let width = rows.map(\.0.count).max() ?? 0
        print("")
        for (name, value) in rows { print("  " + name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + value) }
        print("")
        if problems.isEmpty {
            print("RESULT PASS" + (preferred == nil ? " (no input device: output only)" : ""))
            exit(0)
        }
        print("RESULT FAIL")
        for problem in problems { print("  - \(problem)") }
        exit(1)
    }
}
