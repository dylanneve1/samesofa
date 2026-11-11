// Rooms that do not depend on a film (1.3): two complete peers in one process, through a real
// signalling server over loopback, synthetic camera and microphone.
//
//   samesofa-itest --server ws://127.0.0.1:8787 --room-test a.mp4,b.mp4
//       join with no film; the call both ways for 20 s; film A; play; change to film B in the middle
//       of A's transfer and playback; close the film; A again (only what is missing is fetched);
//       A a third time (nothing is fetched). The peer connection must stay connected throughout,
//       nothing sent for an earlier film may apply to a later one, and both films must arrive byte for byte.
//   samesofa-itest --server ws://127.0.0.1:8787 --resume-test a.mp4,remux.mkv,transcode.mkv
//       resuming across "relaunches" (new peers, same caches), converted films, a damaged copy, the size limit.

import AVFoundation
import CryptoKit
import Foundation
import SameSofaCore
import SameSofaKit
import WebRTC

final class RoomSuite {
    let server: URL
    let start = Date()
    var results: [(String, Bool, String)] = []
    var failed = false
    let work: URL

    init(server: URL) {
        self.server = server
        work = FileManager.default.temporaryDirectory.appendingPathComponent("samesofa-room-suite-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
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

    func finish() -> Never {
        try? FileManager.default.removeItem(at: work)
        let passed = results.filter { $0.1 }.count
        log("SUMMARY \(passed)/\(results.count) checks passed")
        exit(failed ? 1 : 0)
    }

    func settings(_ label: String, hue: Double) -> PartySettings {
        PartySettings(serverURL: server, ice: IceSettings(stunURLs: []), audioMode: .synthetic, camera: .synthetic(label: label, hue: hue))
    }

    func sha256(_ url: URL) -> String { FilmFingerprint.fullHash(file: url) ?? "unreadable" }

    func throttle(_ bytesPerSecond: Int?) {
        if let bytesPerSecond { setenv("SAMESOFA_THROTTLE_BPS", String(bytesPerSecond), 1) } else { unsetenv("SAMESOFA_THROTTLE_BPS") }
    }

    func cache(_ name: String, capacity: Int64 = 1 << 30) -> FilmCache {
        FilmCache(root: work.appendingPathComponent(name, isDirectory: true), capacity: capacity)
    }

    /// A host with an open room and a guest in it, no film.
    func pair(hostCache: FilmCache, guestCache: FilmCache, label: String) -> (host: Party, guest: Party)? {
        let host = Party(role: .host, settings: settings("Host", hue: 0.62))
        let guest = Party(role: .guest, settings: settings("Guest", hue: 0.05))
        host.filmCache = hostCache
        guest.filmCache = guestCache
        guest.playback.testClockSkew = 321.123
        host.openRoom()
        var code = ""
        guard wait(10, { if case .waitingForPartner(let c) = host.phase { code = c; return true }; return false }) else {
            check("\(label): room opens", false, "\(host.phase)")
            return nil
        }
        guest.join(code: code)
        guard wait(20, { host.phase == .together && guest.phase == .together }) else {
            check("\(label): both connected", false, "host=\(host.phase) guest=\(guest.phase)")
            return nil
        }
        return (host, guest)
    }

    func bothPlaying(_ host: Party, _ guest: Party) -> Bool {
        host.playback.player.rate > 0 && guest.playback.player.rate > 0 && !host.playback.isHeld && !guest.playback.isHeld
    }

    func drift(_ host: Party, _ guest: Party) -> Double { abs(host.playback.currentTime - guest.playback.currentTime) }

    /// The states a healthy connection goes through once and never leaves.
    func connectionStayedUp(_ party: Party) -> (Bool, String) {
        let log = party.connectionLog
        let bad = log.filter { $0.hasSuffix("disconnected") || $0.hasSuffix("failed") || $0.hasSuffix("closed") }
        let connected = log.filter { $0.hasSuffix("peer connected") }.count
        let ok = bad.isEmpty && connected == 1 && party.callsStarted == 1 && party.reconnects == 0
        return (ok, "\(log.count) state changes: " + log.map { $0.replacingOccurrences(of: "call 1: ", with: "") }.joined(separator: ", "))
    }

    // MARK: The headline scenario

    func runRoom(filmA: URL, filmB: URL) -> Never {
        let hostCache = cache("host"), guestCache = cache("guest")
        let host = Party(role: .host, settings: settings("Host", hue: 0.62))
        let guest = Party(role: .guest, settings: settings("Guest", hue: 0.05))
        host.filmCache = hostCache
        guest.filmCache = guestCache
        guest.playback.testClockSkew = 321.123

        // 1. A room without a film.
        host.openRoom()
        var code = ""
        check("a room opens without a film", wait(10) { if case .waitingForPartner(let c) = host.phase { code = c; return true }; return false }
              && host.sharedFilm == nil && !host.hasFilmActivity, code.isEmpty ? "\(host.phase)" : "code has \(code.count) characters")
        guest.join(code: code)
        check("both connected, no film", wait(20) { host.phase == .together && guest.phase == .together } && host.sharedFilm == nil,
              "host=\(host.phase) guest=\(guest.phase)")
        if failed { finish() }
        check("the guest knows there is no film and is not waiting for one", wait(5) { guest.guestFilm != nil } && guest.sharedFilm == nil
              && !guest.choosingFilm && guest.preparing == nil && !guest.playback.localBuffering && guest.receiver == nil && guest.versionNote == nil,
              "film number \(guest.guestFilm.map(String.init) ?? "unknown")")

        // 2. The call, both ways, for 20 s.
        let hostFrames = RoomFrameCounter(), guestFrames = RoomFrameCounter()
        wait(10) { host.remoteVideoTrack != nil && guest.remoteVideoTrack != nil }
        host.remoteVideoTrack?.add(hostFrames)
        guest.remoteVideoTrack?.add(guestFrames)
        spin(1)
        var fewestToHost = Int.max, fewestToGuest = Int.max, quietestAtHost: Float = 1, quietestAtGuest: Float = 1
        for _ in 0..<20 {
            let h = hostFrames.count, g = guestFrames.count
            spin(1)
            fewestToHost = min(fewestToHost, hostFrames.count - h)
            fewestToGuest = min(fewestToGuest, guestFrames.count - g)
            quietestAtHost = min(quietestAtHost, host.hub.receivedVoiceLevel)
            quietestAtGuest = min(quietestAtGuest, guest.hub.receivedVoiceLevel)
        }
        check("camera both ways in every second of 20 s without a film", fewestToHost >= 5 && fewestToGuest >= 5,
              "fewest frames in a second: to host \(fewestToHost), to guest \(fewestToGuest)")
        check("voice both ways in every second of 20 s without a film", quietestAtHost > 0.02 && quietestAtGuest > 0.02,
              String(format: "lowest level: at host %.3f, at guest %.3f", quietestAtHost, quietestAtGuest))
        func mediaStillFlows(_ what: String) {
            let h = hostFrames.count, g = guestFrames.count
            spin(2)
            check("\(what): camera and voice go on both ways", hostFrames.count - h >= 10 && guestFrames.count - g >= 10
                    && host.hub.receivedVoiceLevel > 0.02 && guest.hub.receivedVoiceLevel > 0.02,
                  "\(hostFrames.count - h) and \(guestFrames.count - g) frames in 2 s")
        }

        // 3. Film A.
        throttle(1_500_000)
        var sawChoosing = false
        host.changeFilm(to: filmA)
        check("host: the file is being looked at, the room stays", host.choosingFilm && host.phase == .together)
        let aLoaded = wait(60) {
            if guest.choosingFilm { sawChoosing = true }
            return guest.sharedFilm != nil && guest.playback.isLoaded && host.playback.isLoaded
        }
        check("film A arrives on the guest", aLoaded && guest.sharedFilm?.film == host.turn.current && guest.guestFilm == host.turn.current,
              "film number \(host.turn.current), channel \(host.filmChannel ?? "-")")
        check("the guest was told the host is choosing", sawChoosing)
        check("the first film of a call uses the channel every version knows", host.filmChannel == FileInfo.firstChannel)
        let seqA = host.playback.engine.timeline.seq
        guest.playback.play()
        check("film A plays on both sides", wait(30) { self.bothPlaying(host, guest) })
        spin(3)
        check("film A in sync", drift(host, guest) < 0.25, String(format: "%.3f s apart", drift(host, guest)))
        mediaStillFlows("while film A plays and arrives")

        // 4. Film B, in the middle of A's transfer and playback.
        check("film A is still arriving", wait(30) { guest.transferFraction > 0.3 } && guest.transferFraction < 0.95 && bothPlaying(host, guest),
              String(format: "%.0f%% received, playing at %.1f s", guest.transferFraction * 100, guest.playback.currentTime))
        let fractionA = guest.receiver?.fraction ?? 0
        let oldTimeline = host.playback.engine.timeline
        let filmNumberA = host.turn.current
        weak var receiverA = guest.receiver
        let fileA = guest.receiver?.cacheURL
        throttle(3_000_000)
        sawChoosing = false
        host.changeFilm(to: filmB)
        // Whatever the guest sent before it heard about the change is about film A: it must not touch film B.
        let fresh = host.playback.engine.timeline
        host.injectForTesting(.timeline(Timeline(playing: true, position: 30, anchor: host.playback.sharedNow, seq: oldTimeline.seq + 3, origin: .guest)))
        host.injectForTesting(.timeline(Timeline(playing: true, position: 30, anchor: host.playback.sharedNow, seq: fresh.seq + 50, origin: .guest)))
        host.injectForTesting(.buffering(false, position: 30))
        host.injectForTesting(.progress(fraction: 0.99))
        host.injectForTesting(.have(ranges: [[0, 5]]))
        check("host: the change ends film A at once", host.playback.player.currentItem == nil && host.sharedFilm == nil && host.choosingFilm
                && host.turn.current == filmNumberA + 1)
        check("host: late messages about film A do not touch film B", host.playback.engine.timeline == fresh && host.transferFraction == 0
                && host.receivedRanges.isEmpty && !host.playback.intendsToPlay,
              "timeline seq \(host.playback.engine.timeline.seq) (film A ended at \(oldTimeline.seq))")
        check("the new film's sequence numbers continue above the old film's", fresh.seq >= oldTimeline.seq + SyncEngine.filmGap && fresh.seq > seqA,
              "film A from \(seqA) to \(oldTimeline.seq), film B from \(fresh.seq)")
        let bLoaded = wait(60) {
            if guest.choosingFilm { sawChoosing = true }
            return guest.sharedFilm?.film == host.turn.current && guest.playback.isLoaded && host.playback.isLoaded
        }
        check("film B arrives on the guest", bLoaded && guest.sharedFilm?.size == host.sharedFilm?.size, "channel \(host.filmChannel ?? "-")")
        check("guest: 'your partner is choosing another film' was shown in between", sawChoosing)
        check("film B has a channel of its own", host.filmChannel == FileInfo.laterChannelPrefix + String(host.turn.current))
        check("guest: film A's transfer is over and its file closed", wait(5) { receiverA == nil })
        // Late messages from film A, on both sides, now that film B is the film.
        let beforeHost = host.playback.engine.timeline, beforeGuest = guest.playback.engine.timeline
        host.injectForTesting(.timeline(Timeline(playing: true, position: 40, anchor: host.playback.sharedNow, seq: oldTimeline.seq + 2, origin: .guest)))
        guest.injectForTesting(.timeline(Timeline(playing: true, position: 40, anchor: host.playback.sharedNow, seq: oldTimeline.seq + 2, origin: .host)))
        guest.injectForTesting(.heartbeat(oldTimeline, actualPosition: 40))
        spin(0.3)
        check("a play/seek from film A arriving late changes nothing in film B", host.playback.engine.timeline == beforeHost
                && guest.playback.engine.timeline == beforeGuest && host.playback.player.rate == 0 && guest.playback.player.rate == 0)
        host.playback.play()
        check("film B plays on both sides", wait(30) { self.bothPlaying(host, guest) })
        spin(3)
        check("film B in sync", drift(host, guest) < 0.25, String(format: "%.3f s apart", drift(host, guest)))
        check("film B: pause from the guest reaches the host", { guest.playback.pause(); return wait(5) { host.playback.player.rate == 0 && guest.playback.player.rate == 0 } }())
        host.playback.play()
        check("film B arrives completely", wait(120) { guest.receiver?.isComplete == true }, String(format: "%.0f%%", (guest.receiver?.fraction ?? 0) * 100))
        if let receiver = guest.receiver {
            let a = sha256(filmB), b = sha256(receiver.cacheURL)
            check("film B is byte-identical", a == b && a != "unreadable", "sha256 \(a.prefix(16))")
            check("film B's complete copy was checked against the host's hash", wait(20) { receiver.status.verified == true })
            check("only film B's chunks were fetched for film B", receiver.status.fetched == receiver.status.chunkCount && receiver.status.resumed == 0,
                  "\(receiver.status.fetched) of \(receiver.status.chunkCount)")
        }
        mediaStillFlows("while film B plays")

        // 5. Close the film: back to just being in the room.
        check("film B is playing when it is closed", wait(10) { self.bothPlaying(host, guest) })
        host.closeFilm()
        check("closing the film empties both players and keeps the room", wait(10) {
            host.sharedFilm == nil && guest.sharedFilm == nil && host.playback.player.currentItem == nil && guest.playback.player.currentItem == nil
                && guest.receiver == nil && !guest.choosingFilm && !host.hasFilmActivity
        } && host.phase == .together && guest.phase == .together && host.code == code)
        mediaStillFlows("after closing the film")

        // 6. Film A again: what the guest has of it is used.
        throttle(1_500_000)
        host.changeFilm(to: filmA)
        var firstRanges: [ClosedRange<Double>] = [], firstHostRanges: [ClosedRange<Double>] = [], fetchedAtFirstRanges = -1
        let againLoaded = wait(60) {
            if firstRanges.isEmpty, !guest.receivedRanges.isEmpty {
                firstRanges = guest.receivedRanges
                fetchedAtFirstRanges = guest.receiver?.status.fetched ?? -1
            }
            if firstHostRanges.isEmpty, !host.receivedRanges.isEmpty { firstHostRanges = host.receivedRanges }
            return guest.sharedFilm?.film == host.turn.current && guest.playback.isLoaded && !firstHostRanges.isEmpty
        }
        let status = guest.receiver?.status ?? .init()
        check("film A again: the guest's partial copy is reused", againLoaded && status.resumed > 0 && guest.receiver?.cacheURL == fileA
                && Double(status.resumed) / Double(max(1, status.chunkCount)) >= fractionA - 0.02,
              String(format: "%d of %d chunks were already here (%.0f%% when film A was left)", status.resumed, status.chunkCount, fractionA * 100))
        let covered = firstRanges.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        check("the seek bar shows the resumed part at once, on both sides", covered >= fractionA - 0.03 && fetchedAtFirstRanges >= 0
                && fetchedAtFirstRanges <= 30 && !firstHostRanges.isEmpty,
              String(format: "first picture covers %.0f%% after %d fetched chunks; host shows %d range(s)", covered * 100, fetchedAtFirstRanges, firstHostRanges.count))
        check("film A again arrives completely", wait(120) { guest.receiver?.isComplete == true })
        if let receiver = guest.receiver {
            let s = receiver.status
            check("only the missing chunks were fetched", s.fetched == s.chunkCount - s.resumed, "\(s.fetched) fetched, \(s.resumed) resumed, \(s.chunkCount) in all")
            let a = sha256(filmA), b = sha256(receiver.cacheURL)
            check("film A is byte-identical", a == b && a != "unreadable", "sha256 \(a.prefix(16))")
            check("film A's complete copy was checked against the host's hash", wait(20) { receiver.status.verified == true })
        }
        guest.playback.play()
        check("film A again plays on both sides", wait(30) { self.bothPlaying(host, guest) })
        spin(2)
        check("film A again in sync", drift(host, guest) < 0.25, String(format: "%.3f s apart", drift(host, guest)))

        // 7. And once more: now nothing has to be fetched.
        host.closeFilm()
        wait(10) { guest.sharedFilm == nil && guest.receiver == nil }
        let t0 = Date()
        host.changeFilm(to: filmA)
        let thirdLoaded = wait(60) { guest.sharedFilm?.film == host.turn.current && guest.playback.isLoaded && guest.receiver?.isComplete == true }
        let third = guest.receiver?.status ?? .init()
        check("film A a third time: nothing is fetched", thirdLoaded && third.fetched == 0 && third.resumed == third.chunkCount,
              String(format: "ready %.1f s after choosing it; %d chunks fetched", Date().timeIntervalSince(t0), third.fetched))
        check("host: nothing was sent", host.chunksSent == 0, "\(host.chunksSent) chunks")
        check("both show the film as complete", wait(5) { host.transferFraction >= 1 && guest.transferFraction >= 1 })
        host.playback.play()
        check("film A a third time plays on both sides", wait(30) { self.bothPlaying(host, guest) })
        mediaStillFlows("at the end")

        // 8. One connection, connected throughout; the same room.
        for (name, party) in [("host", host), ("guest", guest)] {
            let (ok, detail) = connectionStayedUp(party)
            check("\(name): the peer connection never left 'connected'", ok, detail)
        }
        check("the room code never changed", host.code == code && guest.code == code)
        check("no version note between two copies of the same version", host.versionNote == nil && guest.versionNote == nil)

        guest.leave()
        check("the guest leaving leaves the host in the room with its film", wait(10) { if case .waitingForPartner = host.phase { return true }; return false }
              && host.sharedFilm != nil)
        host.leave()
        finish()
    }
}

/// Counts decoded remote video frames.
final class RoomFrameCounter: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) { lock.lock(); _count += 1; lock.unlock() }
}
