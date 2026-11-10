// End-to-end test: two complete SameSofa peers (host and guest) in one
// process, talking through a real signalling server over loopback, with a
// synthetic camera and microphone (no hardware, no sound out of the speakers).
//
// Usage: samesofa-itest --server ws://127.0.0.1:8787 --film test.mp4 [--soak 120] [--throttle 400000]

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
guard let server = args["server"].flatMap(URL.init(string:)), let filmPath = args["film"] else {
    print("usage: samesofa-itest --server ws://127.0.0.1:8787 --film test.mp4 [--soak seconds] [--throttle bytesPerSecond]")
    exit(2)
}
let filmURL = URL(fileURLWithPath: filmPath)

// Optional: start the real voice-processing audio engine at zero volume and
// report whether it runs on this machine (it needs a microphone).
if args["audio-check"] != nil {
    let hub = AudioHub(mode: .voiceProcessing)
    hub.filmVolume = 0
    hub.voiceVolume = 0
    hub.start()
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    print("voice processing: \(hub.voiceProcessingFailed ? "unavailable, fell back" : "active"); engine: \(hub.engineError ?? "running")")
    hub.stop()
    exit(0)
}
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

let host = Party(role: .host, settings: settings("Host", hue: 0.62))
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
check("audio host->guest", guest.hub.receivedVoiceLevel > 0.02, String(format: "peak %.3f", guest.hub.receivedVoiceLevel))
check("audio guest->host", host.hub.receivedVoiceLevel > 0.02, String(format: "peak %.3f", host.hub.receivedVoiceLevel))

// 3. Guest player becomes ready without having the file
check("guest player ready", wait(60) { guest.playback.isLoaded && !guest.playback.localBuffering && guest.playback.duration > 0 },
      String(format: "duration %.1f, received %.0f%%", guest.playback.duration, guest.transferFraction * 100))

let duration = host.playback.duration
check("clock sync found the skew", wait(5) { abs(guest.playback.clockOffset + skew) < 0.005 },
      String(format: "offset %.4f s (true %.4f), best rtt %.1f ms", guest.playback.clockOffset, -skew, guest.clockRoundTrip * 1000))

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

// 9. Disturbances: knock the guest's player off and watch it come back.
func recovers(within seconds: Double) -> (Bool, Double) {
    let t0 = Date()
    let ok = wait(seconds) { drift() < 0.1 }
    return (ok, Date().timeIntervalSince(t0))
}
spin(2)
guest.playback.player.seek(to: CMTime(seconds: guest.playback.currentTime + 0.7, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
spin(0.3)
var (ok, took) = recovers(within: 15)
check("small drift (0.7 s) corrected smoothly", ok, String(format: "back within 0.1 s after %.1f s", took))
host.playback.player.seek(to: CMTime(seconds: host.playback.currentTime - 4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
spin(0.3)
(ok, took) = recovers(within: 8)
check("large drift (4 s) corrected by seeking", ok, String(format: "back within 0.1 s after %.1f s", took))

// 10. Soak: drift over time
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
    let d = drift()
    samples.append(d)
    worst = max(worst, d)
}
let mean = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
check("drift stays under 0.25 s for \(Int(soakSeconds)) s", worst < 0.25,
      String(format: "max %.3f s, mean %.3f s, %d samples, %d wraps", worst, mean, samples.count, restarts))

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
