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

    // MARK: Resuming

    /// Ends a session the way quitting both apps does.
    func quit(_ host: Party, _ guest: Party) {
        guest.leave()
        host.leave()
        spin(0.5)
    }

    func loaded(_ host: Party, _ guest: Party, _ timeout: Double = 90) -> Bool {
        wait(timeout) { guest.sharedFilm != nil && guest.sharedFilm?.film == host.turn.current && guest.playback.isLoaded && host.playback.isLoaded }
    }

    func runResume(filmA: URL, filmB: URL, rewrapped: URL, converted: URL) -> Never {
        let shaA = sha256(filmA)

        // 1. The guest quits with part of the film, in pieces; both come back.
        throttle(1_500_000)
        var have = 0, ranges = 0, fingerprint = ""
        if let (host, guest) = pair(hostCache: cache("h1"), guestCache: cache("g1"), label: "first session") {
            host.changeFilm(to: filmA)
            check("first session: film A loads", loaded(host, guest))
            guest.playback.play()
            wait(20) { self.bothPlaying(host, guest) }
            host.playback.seek(to: host.playback.duration * 0.7)
            check("first session: the guest has the film in separate pieces", wait(30) { guest.receivedRanges.count >= 2 && guest.transferFraction > 0.25 }
                  && guest.transferFraction < 0.9,
                  guest.receivedRanges.map { String(format: "%.0f-%.0f%%", $0.lowerBound * 100, $0.upperBound * 100) }.joined(separator: " "))
            have = guest.receiver?.status.received ?? 0
            ranges = guest.receivedRanges.count
            fingerprint = guest.sharedFilm?.fingerprint ?? ""
            check("the film is kept in the guest's cache while it is received", guest.receiver?.status.isKept == true && !fingerprint.isEmpty)
            quit(host, guest)
        }
        let kept = cache("g1").entries
        check("after quitting: the partial copy is on disk, not in use", kept.count == 1 && kept.first?.inUse == false && (kept.first?.bytes ?? 0) > 0,
              kept.map { "\($0.bytes >> 20) MB" }.joined(separator: ", "))
        var guestCache = cache("g1")
        if let (host, guest) = pair(hostCache: cache("h1"), guestCache: guestCache, label: "after both relaunched") {
            var firstRanges: [ClosedRange<Double>] = [], firstHostRanges: [ClosedRange<Double>] = []
            host.changeFilm(to: filmA)
            let ok = wait(60) {
                if firstRanges.isEmpty, !guest.receivedRanges.isEmpty { firstRanges = guest.receivedRanges }
                if firstHostRanges.isEmpty, !host.receivedRanges.isEmpty { firstHostRanges = host.receivedRanges }
                return guest.sharedFilm != nil && guest.playback.isLoaded && !firstHostRanges.isEmpty
            }
            let status = guest.receiver?.status ?? .init()
            check("guest relaunched: the partial copy is found again", ok && status.resumed >= have && status.resumed <= have + 40
                    && guest.sharedFilm?.fingerprint == fingerprint, "\(status.resumed) of \(status.chunkCount) chunks (had \(have) when it quit)")
            check("guest relaunched: the seek bar shows the pieces at once, on both sides", firstRanges.count >= 2 && ranges >= 2
                    && firstHostRanges.count == firstRanges.count,
                  firstRanges.map { String(format: "%.0f-%.0f%%", $0.lowerBound * 100, $0.upperBound * 100) }.joined(separator: " "))
            check("guest relaunched: the rest arrives", wait(120) { guest.receiver?.isComplete == true })
            if let receiver = guest.receiver {
                let s = receiver.status
                check("guest relaunched: only the missing chunks were fetched", s.fetched == s.chunkCount - s.resumed, "\(s.fetched) fetched, \(s.resumed) resumed")
                check("guest relaunched: byte-identical", sha256(receiver.cacheURL) == shaA && shaA != "unreadable")
                check("guest relaunched: checked against the host's hash", wait(20) { receiver.status.verified == true })
            }
            guest.playback.play()
            check("guest relaunched: plays in sync", wait(30) { self.bothPlaying(host, guest) } && { spin(2); return drift(host, guest) < 0.25 }())
            quit(host, guest)
        }

        // 2. The host quits and comes back (a new room); the guest's app kept running.
        if let (host, guest) = pair(hostCache: cache("h1"), guestCache: guestCache, label: "after the host relaunched") {
            let t0 = Date()
            host.changeFilm(to: filmA)
            check("host relaunched: the guest's complete copy is used", loaded(host, guest) && wait(10) { guest.receiver?.isComplete == true },
                  String(format: "ready after %.1f s", Date().timeIntervalSince(t0)))
            let s = guest.receiver?.status ?? .init()
            check("host relaunched: nothing is fetched, nothing is sent", s.fetched == 0 && s.resumed == s.chunkCount && host.chunksSent == 0, "\(s.fetched) fetched")
            check("host relaunched: checked against the host's hash again", wait(20) { guest.receiver?.status.verified == true })
            quit(host, guest)
        }

        // 3. A kept copy that got damaged on disk: found out by the hash, fetched again.
        if let file = try? FileManager.default.contentsOfDirectory(at: work.appendingPathComponent("g1/received"), includingPropertiesForKeys: nil).first?
            .appendingPathComponent("film.bin"), let handle = try? FileHandle(forWritingTo: file) {
            try? handle.seek(toOffset: 5_000_000)
            try? handle.write(contentsOf: Data(repeating: 0xAA, count: 3000))
            try? handle.close()
            guestCache = cache("g1")
            if let (host, guest) = pair(hostCache: cache("h1"), guestCache: guestCache, label: "damaged copy") {
                host.changeFilm(to: filmA)
                check("damaged copy: taken at first (it is complete)", loaded(host, guest) && guest.receiver?.status.resumed == guest.receiver?.status.chunkCount)
                check("damaged copy: the hash does not match, the kept part is fetched again", wait(120) {
                    let s = guest.receiver?.status ?? .init()
                    return s.refetches == 1 && s.received == s.chunkCount && s.verified == true
                }, "\(guest.receiver?.status.fetched ?? 0) chunks fetched")
                if let receiver = guest.receiver { check("damaged copy: byte-identical in the end", sha256(receiver.cacheURL) == shaA) }
                quit(host, guest)
            }
        } else {
            check("damaged copy: the kept file is where it should be", false)
        }

        // 4. Converted films. The host keeps what it converted: sharing the film again
        //    converts nothing and sends the very same bytes, so the guest's copy still fits.
        throttle(nil)
        for (film, label, partial) in [(rewrapped, "rewrapped MKV", false), (converted, "converted MKV", true)] {
            var first = "", sharedPath = "", sentSha = "", haveBefore = 0
            let hostRoot = "h-\(label.prefix(3))", guestRoot = "g-\(label.prefix(3))"
            if partial { throttle(250_000) } else { throttle(nil) }
            if let (host, guest) = pair(hostCache: cache(hostRoot), guestCache: cache(guestRoot), label: label) {
                let t0 = Date()
                host.changeFilm(to: film)
                let ok = wait(180) { host.sharedFilm != nil }
                let took = Date().timeIntervalSince(t0)
                check("\(label): prepared on the host and kept in its cache", ok && host.conversionsRun == 1 && (host.sharedFile?.path.contains("/\(hostRoot)/prepared/") ?? false),
                      String(format: "%.1f s", took))
                first = host.sharedFilm?.fingerprint ?? ""
                sharedPath = host.sharedFile?.path ?? ""
                sentSha = host.sharedFile.map(sha256) ?? ""
                if partial {
                    check("\(label): the guest has part of it", wait(60) { guest.transferFraction > 0.3 } && guest.transferFraction < 0.95,
                          String(format: "%.0f%%", guest.transferFraction * 100))
                    haveBefore = guest.receiver?.status.received ?? 0
                } else {
                    check("\(label): arrives completely", wait(120) { guest.receiver?.isComplete == true })
                    check("\(label): byte-identical to what the host converted", guest.receiver.map { sha256($0.cacheURL) } == sentSha && sentSha != "unreadable")
                }
                quit(host, guest)
            }
            check("\(label): the converted film stays on the host after the session", FileManager.default.fileExists(atPath: sharedPath))
            throttle(nil)
            if let (host, guest) = pair(hostCache: cache(hostRoot), guestCache: cache(guestRoot), label: "\(label) again") {
                let t0 = Date()
                host.changeFilm(to: film)
                let ok = wait(60) { host.sharedFilm != nil }
                check("\(label) again: not converted a second time, the same bytes are shared", ok && host.conversionsRun == 0 && host.sharedFile?.path == sharedPath
                        && host.sharedFilm?.fingerprint == first && !first.isEmpty, String(format: "shared after %.1f s", Date().timeIntervalSince(t0)))
                check("\(label) again: loads on the guest", loaded(host, guest) && wait(120) { guest.receiver?.isComplete == true })
                let s = guest.receiver?.status ?? .init()
                if partial {
                    check("\(label) again: the guest's partial copy is completed, only the missing chunks fetched",
                          s.resumed >= haveBefore && s.resumed > 0 && s.fetched == s.chunkCount - s.resumed, "\(s.fetched) fetched, \(s.resumed) resumed")
                } else {
                    check("\(label) again: nothing is fetched", s.fetched == 0 && s.resumed == s.chunkCount, "\(s.fetched) fetched")
                }
                check("\(label) again: byte-identical and checked", guest.receiver.map { sha256($0.cacheURL) } == sentSha
                        && wait(20) { guest.receiver?.status.verified == true })
                host.playback.play()
                check("\(label) again: plays in sync", wait(30) { self.bothPlaying(host, guest) } && { spin(2); return drift(host, guest) < 0.25 }())
                quit(host, guest)
            }
        }

        // 5. The size limit. Film A is about 37 MB, film B about 20 MB.
        let sizeA = Int64((try? FileManager.default.attributesOfItem(atPath: filmA.path)[.size] as? NSNumber)??.int64Value ?? 0)
        let sizeB = Int64((try? FileManager.default.attributesOfItem(atPath: filmB.path)[.size] as? NSNumber)??.int64Value ?? 0)
        let limited = cache("g-cap", capacity: sizeA + sizeB / 2)
        if let (host, guest) = pair(hostCache: cache("h1"), guestCache: limited, label: "size limit") {
            host.changeFilm(to: filmA)
            check("size limit: film A arrives and is kept", loaded(host, guest) && wait(120) { guest.receiver?.isComplete == true } && limited.entries.count == 1)
            host.changeFilm(to: filmB)
            check("size limit: film B arrives", loaded(host, guest) && wait(120) { guest.receiver?.isComplete == true })
            let entries = limited.entries
            check("size limit: the older film made room for the new one", entries.count == 1 && guest.receiver?.status.isKept == true
                    && limited.totalBytes <= limited.capacity, "\(entries.count) kept, \(limited.totalBytes >> 20) MB of \(limited.capacity >> 20) MB")
            // A film in use is never removed, however small the limit becomes.
            limited.capacity = 1 << 20
            limited.sweep()
            check("size limit: the film being watched is never removed", limited.entries.count == 1 && FileManager.default.fileExists(atPath: guest.receiver?.cacheURL.path ?? "/nope"))
            // Bigger than the limit: received as before 1.3, into a temporary file that goes with the film.
            host.changeFilm(to: filmA)
            check("size limit: a film bigger than the limit still plays", loaded(host, guest))
            let temporary = guest.receiver?.cacheURL
            check("size limit: it is not kept", guest.receiver?.status.isKept == false && !(temporary?.path.contains("/g-cap/") ?? true))
            host.closeFilm()
            check("size limit: its temporary file goes when the film is closed", wait(10) { guest.receiver == nil }
                  && !FileManager.default.fileExists(atPath: temporary?.path ?? "/nope"))
            quit(host, guest)
        }
        // After 24 hours without use a kept film goes.
        let aged = cache("g1")
        let before = aged.entries
        for entry in before { aged.setLastUsedForTesting(entry.id, Date().addingTimeInterval(-25 * 3600)) }
        aged.sweep()
        check("a kept film not used for 24 hours is removed", !before.isEmpty && aged.entries.isEmpty, "\(before.count) before, \(aged.entries.count) after")
        let switchedOff = cache("g-off", capacity: 0)
        check("with keeping switched off nothing is kept", switchedOff.openReceived(info: FileInfo(size: 1000, name: "x.mp4", uti: "public.mpeg-4", fingerprint: "abc")) == nil)
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
