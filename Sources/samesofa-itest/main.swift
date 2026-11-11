// End-to-end test: two complete SameSofa peers (host and guest) in one
// process, talking through a real signalling server over loopback, with a
// synthetic camera and microphone (no hardware, no sound out of the speakers).
//
// Usage: samesofa-itest --server ws://127.0.0.1:8787 --film test.mp4 [--soak 120] [--throttle 400000]
//        samesofa-itest --server ws://127.0.0.1:8787 --convert-suite a.mkv,b.avi,...   (see ConversionSuite.swift)

import AVFoundation
import CryptoKit
import Foundation
import SameSofaCore
import SameSofaKit
import WebRTC

setvbuf(stdout, nil, _IOLBF, 0)

var args = [String: String]()
var argv = CommandLine.arguments.dropFirst()
while let key = argv.popFirst() {
    if key.hasPrefix("--") { args[String(key.dropFirst(2))] = argv.popFirst() ?? "" }
}
// Optional: start the real call audio engine at zero volume and report
// whether it runs on this machine, and what the sound output is.
if args["audio-check"] != nil {
    let hub = AudioHub(mode: .live)
    hub.voiceVolume = 0
    hub.start()
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    let route = hub.outputRoute
    print("call audio engine: \(hub.engineError ?? "running"); microphone: \(AVCaptureDevice.default(for: .audio) == nil ? "none" : "present")")
    print("output: \(route.name) [\(route.transport.rawValue)\(route.dataSource.map { ", source \($0)" } ?? "")] -> \(route.kind.rawValue); film echo cancellation: \(hub.cancelsFilmEcho ? "on" : "off")")
    hub.stop()
    exit(0)
}
// The call's audio threads and the microphone converter, without any hardware.
if args["device-smoke"] != nil { DeviceSmoke.run(args) }
if let server = args["connection-test"] { ConnectionTest.run(server: server) }
if args["display-mode-test"] != nil { DisplayModeTest.run(switchForReal: args["switch"] != nil) }
if args["audio-thread-test"] != nil { AudioThreadTests.runThreadTest() }
if let film = args["audio-engine-test"] {
    AudioThreadTests.runEngineTest(film: film.isEmpty ? nil : URL(fileURLWithPath: film), realSwitch: args["real-output-switch"] != nil)
}
// Film sound path measurements and the echo canceller simulation (no sound is played).
if let list = args["audio-measure"] {
    FilmPathMeasure.run(files: list.split(separator: ",").map { URL(fileURLWithPath: String($0)) }, referenceFFmpeg: args["reference-ffmpeg"],
                        seconds: Double(args["seconds"] ?? "5") ?? 5)
}
if let list = args["echo-sim"] {
    let files = list.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
    guard files.count == 2 else { print("usage: --echo-sim film.wav,talker.wav [--dump directory]"); exit(2) }
    EchoSim.run(filmURL: files[0], talkerURL: files[1], dump: args["dump"].map { URL(fileURLWithPath: $0) })
}

// Damaged video timestamps: detection, repair, fallback.
if let directory = args["timestamp-suite"] {
    TimestampSuite.run(workDirectory: URL(fileURLWithPath: directory), referenceFFmpeg: args["reference-ffmpeg"] ?? "/opt/homebrew/bin/ffmpeg",
                       healthy: (args["healthy"] ?? "").split(separator: ",").map { URL(fileURLWithPath: String($0)) })
}

if let directory = args["timestamp-edge-suite"] {
    TimestampEdgeSuite.run(workDirectory: URL(fileURLWithPath: directory), referenceFFmpeg: args["reference-ffmpeg"] ?? "/opt/homebrew/bin/ffmpeg", only: args["only"])
}

// Conversion suite: MKV/AVI/... converted on the host, played in sync on the guest.
if let list = args["convert-bench"] {
    ConversionSuite(server: URL(string: "ws://unused")!, referenceFFmpeg: nil)
        .benchmark(films: list.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
}
if let list = args["convert-suite"], let server = args["server"].flatMap(URL.init(string:)) {
    let films = list.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
    ConversionSuite(server: server, referenceFFmpeg: args["reference-ffmpeg"]).run(films: films)
}

guard let server = args["server"].flatMap(URL.init(string:)), let filmPath = args["film"] else {
    print("usage: samesofa-itest --server ws://127.0.0.1:8787 --film test.mp4 [--soak seconds] [--throttle bytesPerSecond]")
    exit(2)
}
let filmURL = URL(fileURLWithPath: filmPath)


let soakSeconds = Double(args["soak"] ?? "120") ?? 120
if let throttle = args["throttle"] { setenv("SAMESOFA_THROTTLE_BPS", throttle, 1) }

let start = Date()
var results: [(String, Bool, String)] = []
var failed = false

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

/// Uplink slower than the film's bitrate: the guest must run dry, both
/// sides must pause together, and resume together once it has caught up.
func runBufferingScenario() {
    guest.playback.play()
    var sawHold = false, resumedAfterHold = false, worstWhilePlaying = 0.0
    let end = Date().addingTimeInterval(soakSeconds)
    var stableSince: Date?
    while Date() < end {
        spin(0.25)
        let both = host.playback.player.rate > 0 && guest.playback.player.rate > 0
        if host.playback.isHeld || guest.playback.isHeld { sawHold = true; stableSince = nil }
        if sawHold, both { resumedAfterHold = true }
        if both {
            if stableSince == nil { stableSince = Date() }
            if Date().timeIntervalSince(stableSince!) > 2 { worstWhilePlaying = max(worstWhilePlaying, drift()) }
        } else {
            stableSince = nil
        }
    }
    check("guest ran out of film and both paused", sawHold, "holds: host \(host.playback.holdCount) guest \(guest.playback.holdCount)")
    check("both resumed together after buffering", resumedAfterHold)
    check("in sync whenever both were playing", worstWhilePlaying < 0.25, String(format: "max drift %.3f s", worstWhilePlaying))
    check("transfer progress reached host", host.transferFraction > 0, String(format: "%.0f%%", host.transferFraction * 100))
    guest.leave()
    host.leave()
    finish()
}

/// Control messages while the film saturates the link: 10 pause, 10 play and
/// 10 seek commands from each side; time until the other side's timeline moves.
func runControlLatency() {
    func measure(_ label: String, from: Party, to: Party) -> [Double] {
        var out: [Double] = []
        let dur = max(10, from.playback.duration)
        for i in 0..<30 {
            let before = to.playback.engine.timeline.seq
            let t0 = Date()
            switch i % 3 {
            case 0: from.playback.pause()
            case 1: from.playback.play()
            default: from.playback.seek(to: dur * Double(i % 7 + 1) / 9)
            }
            if wait(5, { to.playback.engine.timeline.seq != before }) { out.append(Date().timeIntervalSince(t0) * 1000) } else { out.append(5000) }
            spin(0.15)
        }
        out.sort()
        let p50 = out[out.count / 2], p95 = out[Int(Double(out.count) * 0.95) - 1]
        log(String(format: "control latency %@: p50 %.0f ms, p95 %.0f ms, max %.0f ms (transfer %.0f%%)", label, p50, p95, out.last!, to.transferFraction * 100))
        check("control latency p95 < 250 ms (\(label))", p95 < 250, String(format: "p50 %.0f p95 %.0f", p50, p95))
        return out
    }
    _ = measure("host->guest", from: host, to: guest)
    _ = measure("guest->host", from: guest, to: host)
    guest.leave()
    host.leave()
    finish()
}

/// Seeks into film the guest does not have yet (throttled link): time until both play again.
func runSeekScenario() {
    let dur = host.playback.duration
    let size = Double((try? FileManager.default.attributesOfItem(atPath: filmURL.path)[.size] as? NSNumber)??.int64Value ?? 0)
    let rate = Double(args["throttle"] ?? "0") ?? 0
    func bothPlaying() -> Bool { host.playback.player.rate > 0 && guest.playback.player.rate > 0 && !host.playback.isHeld && !guest.playback.isHeld }
    func jump(_ frac: Double, from: Party, label: String, maxWait: Double) -> Double {
        let t0 = Date()
        from.playback.seek(to: dur * frac)
        from.playback.play()
        let ok = wait(maxWait) { bothPlaying() && abs(guest.playback.currentTime - dur * frac) < 20 }
        let took = Date().timeIntervalSince(t0)
        let expected = rate > 0 ? (size / dur * 8) / rate : 0
        check("seek \(label): both playing again", ok, String(format: "%.1f s (8 s of film = %.1f s of link)", took, expected))
        return took
    }
    host.playback.play()
    spin(2)
    _ = jump(0.5, from: host, label: "host to 50%", maxWait: 90)
    _ = jump(0.9, from: guest, label: "guest to 90%", maxWait: 90)
    // Scrub: ten quick seeks; only the last matters.
    let t0 = Date()
    for i in 0..<10 { host.playback.seek(to: dur * (0.1 + 0.05 * Double(i))); spin(0.15) }
    let final = dur * 0.55
    host.playback.seek(to: final)
    host.playback.play()
    let ok = wait(90) { bothPlaying() && abs(guest.playback.currentTime - final) < 20 }
    check("scrub through 10 positions: playing at the last one", ok, String(format: "%.1f s", Date().timeIntervalSince(t0)))
    // Back into data that has already arrived.
    spin(3)
    let t1 = Date()
    host.playback.seek(to: dur * 0.5 + 1)
    let back = wait(5) { bothPlaying() && abs(guest.playback.currentTime - (dur * 0.5 + 1)) < 3 }
    check("seek back into received film is quick", back && Date().timeIntervalSince(t1) < 3, String(format: "%.2f s", Date().timeIntervalSince(t1)))
    check("transfer completes", wait(400) { guest.receiver?.isComplete == true }, String(format: "%.0f%%", (guest.receiver?.fraction ?? 0) * 100))
    if let receiver = guest.receiver {
        let a = sha256(filmURL), b = sha256(receiver.cacheURL)
        check("received file is byte-identical", a == b, "sha256 \(a.prefix(16))")
    }
    guest.leave()
    host.leave()
    finish()
}

func finish() -> Never {
    let passed = results.filter { $0.1 }.count
    log("SUMMARY \(passed)/\(results.count) checks passed")
    exit(failed ? 1 : 0)
}

/// Counts decoded remote video frames.
final class FrameCounter: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) { lock.lock(); _count += 1; lock.unlock() }
}

func settings(_ label: String, hue: Double) -> PartySettings {
    // Loopback: host candidates are enough, no STUN needed.
    PartySettings(serverURL: server, ice: IceSettings(stunURLs: []), audioMode: .synthetic, camera: .synthetic(label: label, hue: hue))
}

// --live-audio: the host uses the real call audio engine (silent: all volumes
// at zero) instead of the synthetic one, to exercise it and its device-change handling.
let liveAudio = args["live-audio"] != nil
var hostSettings = settings("Host", hue: 0.62)
if liveAudio { hostSettings.audioMode = .live }
let host = Party(role: .host, settings: hostSettings)
if liveAudio { host.filmVolume = 0; host.voiceVolume = 0 }
let hostAudio = FilmPathMeasure.Capture()
host.playback.filmAudioMonitor = hostAudio.monitor()
let guest = Party(role: .guest, settings: settings("Guest", hue: 0.05))
// Pretend the guest's clock is wildly different from the host's, as it would
// be on two real machines; clock sync has to discover this.
let skew = Double(args["skew"] ?? "1234.567") ?? 0
guest.playback.testClockSkew = skew
let throttled = args["throttle"] != nil

// 1. Room by code
do {
    try host.host(film: filmURL)
} catch {
    check("host opens film", false, "\(error)")
    finish()
}
var code = ""
check("room created", wait(10) {
    if case .waitingForPartner(let c) = host.phase { code = c; return true }
    return false
}, code)
check("code has 6 characters", RoomCode.normalize(code) != nil)

// Type it the way a person might.
let typed = code.lowercased().prefix(3) + "-" + code.lowercased().suffix(3)
guest.join(code: String(typed))
check("both connected", wait(20) { host.phase == .together && guest.phase == .together },
      "host=\(host.phase) guest=\(guest.phase)")
if failed { finish() }

// 2. Camera and microphone in both directions
let hostFrames = FrameCounter(), guestFrames = FrameCounter()
wait(10) { host.remoteVideoTrack != nil && guest.remoteVideoTrack != nil }
host.remoteVideoTrack?.add(hostFrames)
guest.remoteVideoTrack?.add(guestFrames)
spin(3)
check("video host->guest", guestFrames.count > 10, "\(guestFrames.count) frames in 3 s")
check("video guest->host", hostFrames.count > 10, "\(hostFrames.count) frames in 3 s")
if liveAudio {
    check("live call audio engine runs on the host", host.hub.engineError == nil, host.hub.engineError ?? "output: \(host.hub.outputRoute.name)")
} else {
    check("audio host->guest", guest.hub.receivedVoiceLevel > 0.02, String(format: "peak %.3f", guest.hub.receivedVoiceLevel))
}
check("audio guest->host", host.hub.receivedVoiceLevel > 0.02, String(format: "peak %.3f", host.hub.receivedVoiceLevel))

// 3. Guest player becomes ready without having the file
check("guest player ready", wait(60) { guest.playback.isLoaded && !guest.playback.localBuffering && guest.playback.duration > 0 },
      String(format: "duration %.1f, received %.0f%%", guest.playback.duration, guest.transferFraction * 100))

let duration = host.playback.duration
check("clock sync found the skew", wait(5) { abs(guest.playback.clockOffset + skew) < 0.005 },
      String(format: "offset %.4f s (true %.4f), best rtt %.1f ms", guest.playback.clockOffset, -skew, guest.clockRoundTrip * 1000))

if args["control-latency"] != nil { runControlLatency() }
if args["seek-test"] != nil { runSeekScenario() }
if throttled { runBufferingScenario() }

func positions() -> (Double, Double) { (host.playback.currentTime, guest.playback.currentTime) }
func drift() -> Double { let (h, g) = positions(); return abs(h - g) }

// 4. Guest presses play
guest.playback.play()
spin(3)
var (h, g) = positions()
check("play from guest starts both", host.playback.player.rate > 0 && guest.playback.player.rate > 0 && h > 1 && g > 1,
      String(format: "host %.2f guest %.2f", h, g))
check("in sync after start", drift() < 0.25, String(format: "drift %.3f s", drift()))

// 5. Host pauses
host.playback.pause()
spin(1.5)
(h, g) = positions()
check("pause from host stops both", host.playback.player.rate == 0 && guest.playback.player.rate == 0,
      String(format: "rates %.2f / %.2f", host.playback.player.rate, guest.playback.player.rate))
check("paused at same frame", drift() < 0.1, String(format: "host %.3f guest %.3f", h, g))

// 6. Guest seeks while paused
let seekTarget = min(60, duration * 0.4)
guest.playback.seek(to: seekTarget)
spin(2)
(h, g) = positions()
check("seek from guest moves host", abs(h - seekTarget) < 0.2 && abs(g - seekTarget) < 0.2, String(format: "host %.2f guest %.2f", h, g))

// 7. Host plays, then seeks backwards while playing
host.playback.play()
spin(3)
let back = seekTarget - 20
host.playback.seek(to: back)
spin(3)
(h, g) = positions()
check("seek while playing from host", abs(h - (back + 3)) < 0.6 && drift() < 0.25, String(format: "host %.2f guest %.2f", h, g))

// 8. Guest pauses, guest resumes
guest.playback.pause()
spin(1)
check("pause from guest stops host", host.playback.player.rate == 0)
guest.playback.play()
spin(2)
check("play from guest resumes host", host.playback.player.rate > 0)

// 8b. Call and sound-path changes while the film plays must leave the film alone.
spin(3)
func offset(_ party: Party) -> Double { party.playback.currentTime - party.playback.engine.targetPosition(at: party.playback.sharedNow) }
do {
    let hostBefore = offset(host), guestBefore = offset(guest)
    let hostRateChanges = host.playback.rateChangeCount, gaps = hostAudio.snapshot.discontinuities, restarts = host.hub.engineRestarts
    host.micOn = false; spin(0.4); host.micOn = true
    guest.micOn = false; spin(0.4); guest.micOn = true
    host.hub.echoSetting = .headphones; spin(0.4)
    host.hub.echoSetting = .speakers; spin(0.4)
    host.hub.echoSetting = .automatic
    if !liveAudio { host.filmVolume = 0.4; spin(0.3); host.filmVolume = 1 }
    host.hub.simulateDeviceChange(); spin(0.5)
    host.hub.stop(); spin(0.3); host.hub.start(); spin(1.5)
    let hostMoved = abs(offset(host) - hostBefore), guestMoved = abs(offset(guest) - guestBefore)
    check("mute, echo setting, volume and device changes leave the host's film alone",
          host.playback.player.rate == 1 && host.playback.rateChangeCount == hostRateChanges && hostMoved < 0.042
            && hostAudio.snapshot.discontinuities == gaps,
          String(format: "rate %.3f, %d speed changes, position moved %.1f ms against the timeline, %d breaks in the sound, %d engine rebuilds",
                 host.playback.player.rate, host.playback.rateChangeCount - hostRateChanges, hostMoved * 1000,
                 hostAudio.snapshot.discontinuities - gaps, host.hub.engineRestarts - restarts))
    check("the same changes leave the guest's film alone", abs(guest.playback.player.rate - 1) < 0.0101 && guestMoved < 0.042,
          String(format: "rate %.3f, position moved %.1f ms against the timeline", guest.playback.player.rate, guestMoved * 1000))
    if liveAudio { check("device change rebuilt the call audio engine", host.hub.engineRestarts > restarts && host.hub.engineError == nil) }
}

// 9. Disturbances: knock the guest's player off and watch it come back.
func recovers(within seconds: Double) -> (Bool, Double) {
    let t0 = Date()
    let ok = wait(seconds) { drift() < 0.1 }
    return (ok, Date().timeIntervalSince(t0))
}
spin(2)
// (A seek on a playing player costs it a varying amount of time, so the size of the knock is measured, and repeated if it came out too small.)
var knockedBy = 0.0
for _ in 0..<4 {
    var knockDone = false
    guest.playback.player.seek(to: CMTime(seconds: guest.playback.currentTime + 0.3, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in knockDone = true }
    wait(3) { knockDone }
    spin(0.1)
    knockedBy = drift()
    if knockedBy > 0.08 && knockedBy < 0.33 { break }
    wait(30) { drift() < 0.03 && guest.playback.player.rate == 1 }
}
var largestNudge = 0.0
let nudgeStart = Date()
var ok = wait(40) {
    if guest.playback.player.rate > 0 { largestNudge = max(largestNudge, abs(Double(guest.playback.player.rate) - 1)) }
    return drift() < 0.03
}
var took = Date().timeIntervalSince(nudgeStart)
check("small drift closed by a speed change of at most 1 %", knockedBy > 0.08 && ok && largestNudge > 0 && largestNudge <= 0.0101,
      String(format: "knocked off by %.0f ms, within 30 ms after %.1f s, largest speed change %.2f %%", knockedBy * 1000, took, largestNudge * 100))
check("speed back to exactly 1 once the gap is closed", wait(20) { guest.playback.player.rate == 1 } && host.playback.player.rate == 1,
      String(format: "guest %.4f host %.4f", guest.playback.player.rate, host.playback.player.rate))
guest.playback.player.seek(to: CMTime(seconds: guest.playback.currentTime + 0.7, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
spin(0.3)
(ok, took) = recovers(within: 8)
check("medium drift (0.7 s) corrected by seeking", ok, String(format: "back within 0.1 s after %.1f s", took))
host.playback.player.seek(to: CMTime(seconds: host.playback.currentTime - 4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
spin(0.3)
(ok, took) = recovers(within: 8)
check("large drift (4 s) corrected by seeking", ok, String(format: "back within 0.1 s after %.1f s", took))

// 10. Soak: drift over time
let soakHostNudges = host.playback.nudgeCount, soakGuestNudges = guest.playback.nudgeCount, soakReanchors = host.playback.reanchorCount
var soakLargestNudge = 0.0
var worst = 0.0, samples: [Double] = []
let soakEnd = Date().addingTimeInterval(soakSeconds)
var restarts = 0
while Date() < soakEnd {
    spin(0.5)
    if host.playback.currentTime > duration - 5 {
        // Wrap before the end of the test film.
        host.playback.seek(to: 5)
        restarts += 1
        spin(2)
        continue
    }
    for rate in [host.playback.player.rate, guest.playback.player.rate] where rate > 0 { soakLargestNudge = max(soakLargestNudge, abs(Double(rate) - 1)) }
    let d = drift()
    samples.append(d)
    worst = max(worst, d)
}
let mean = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
check("drift stays under 0.25 s for \(Int(soakSeconds)) s", worst < 0.25,
      String(format: "max %.3f s, mean %.3f s, %d samples, %d wraps", worst, mean, samples.count, restarts))

check("host never changes speed; guest nudges stay within 1 %", host.playback.nudgeCount == 0 && soakLargestNudge <= 0.0101,
      String(format: "host nudges %d, host timeline moves %d, guest nudges %d, largest speed change %.2f %%",
             host.playback.nudgeCount - soakHostNudges, host.playback.reanchorCount - soakReanchors,
             guest.playback.nudgeCount - soakGuestNudges, soakLargestNudge * 100))
check("each film's sound was set up exactly once", host.playback.audioSetupCount == 1 && guest.playback.audioSetupCount == 1,
      "host \(host.playback.audioSetupCount), guest \(guest.playback.audioSetupCount)")

// 11. Whole file arrives byte-exact
host.playback.pause()
check("transfer completes", wait(300) { guest.receiver?.isComplete == true },
      String(format: "%.0f%%", (guest.receiver?.fraction ?? 0) * 100))
func sha256(_ url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "unreadable" }
    var hasher = SHA256()
    while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
if let receiver = guest.receiver {
    let a = sha256(filmURL), b = sha256(receiver.cacheURL)
    check("received file is byte-identical", a == b, "sha256 \(a.prefix(16))… vs \(b.prefix(16))…")
}

// 12. Leaving
guest.leave()
check("host sees partner leave and waits again", wait(10) {
    if case .waitingForPartner = host.phase { return true }
    return false
})
host.leave()
finish()
