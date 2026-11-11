import XCTest
@testable import SameSofaCore

/// Rooms that do not depend on a film, changing film, resuming (1.3).
final class ProtocolThreeTests: XCTestCase {
    func testNewMessagesRoundTrip() {
        let info = FileInfo(size: 1000, name: "Film.mp4", uti: "public.mpeg-4", film: 4, channel: "film-4", seq: 3000, fingerprint: "abc123")
        let messages: [ControlMessage] = [
            .fileInfo(info), .filmChanging(film: 5, seq: 4000), .noFilm(film: 6, seq: 5000), .filmAck(film: 6),
            .filmHash(film: 4, sha256: "00ff"), .pong(t0: 1, t1: 2, hold: 0.004), .pong(t0: 1, t1: 2),
            .upNext(name: "Episode 2"), .upNext(name: nil), .prefetch(info), .prefetchStop, .prefetchWant(chunks: [0, 5]),
            .prefetchProgress(fraction: 0.5), .nextIn(seconds: 5, name: "Episode 2"), .nextCancel,
        ]
        for message in messages { XCTAssertEqual(ControlMessage.decode(message.encoded()), message) }
    }

    /// What 1.2.1 and earlier send must still be understood, and what they do not know must not be needed.
    func testOlderMessagesStillDecode() {
        let oldFileInfo = #"{"fileInfo":{"_0":{"size":1000,"name":"Film.mp4","uti":"public.mpeg-4","chunkSize":65536,"videoConverted":false,"audioConverted":false}}}"#
        guard case .fileInfo(let info)? = ControlMessage.decode(Data(oldFileInfo.utf8)) else { return XCTFail("old fileInfo") }
        XCTAssertNil(info.film)
        XCTAssertNil(info.channel)
        XCTAssertNil(info.seq)
        XCTAssertNil(info.fingerprint)
        XCTAssertEqual(info.size, 1000)
        let oldPong = #"{"pong":{"t0":1.5,"t1":99.25}}"#
        XCTAssertEqual(ControlMessage.decode(Data(oldPong.utf8)), .pong(t0: 1.5, t1: 99.25, hold: nil))
    }

    /// An older copy decodes with exactly the fields it knows: extra keys in a message it knows must not
    /// make it fail, and messages it does not know must come out as "nothing" (they are then ignored).
    func testOlderCopiesCanReadWhatWeSend() throws {
        struct OldFileInfo: Codable { var size: Int64; var name: String; var uti: String; var chunkSize: Int; var videoConverted: Bool?; var audioConverted: Bool? }
        enum OldMessage: Codable {
            case hello(role: PeerRole, protocolVersion: Int)
            case fileInfo(OldFileInfo)
            case pong(t0: Double, t1: Double)
            case preparing(fraction: Double)
            case bye
        }
        func old(_ message: ControlMessage) -> OldMessage? { try? JSONDecoder().decode(OldMessage.self, from: message.encoded()) }
        let info = FileInfo(size: 1000, name: "Film.mp4", uti: "public.mpeg-4", film: 4, channel: "file", seq: 3000, fingerprint: "abc")
        guard case .fileInfo(let seen)? = old(.fileInfo(info)) else { return XCTFail("an older copy cannot read fileInfo") }
        XCTAssertEqual(seen.size, 1000)
        guard case .pong(let t0, let t1)? = old(.pong(t0: 1, t1: 2, hold: 0.01)) else { return XCTFail("an older copy cannot read pong") }
        XCTAssertEqual(t0, 1)
        XCTAssertEqual(t1, 2)
        XCTAssertNil(old(.filmChanging(film: 1, seq: 1000)))
        XCTAssertNil(old(.noFilm(film: 1, seq: 1000)))
        XCTAssertNil(old(.filmAck(film: 1)))
        XCTAssertNil(old(.filmHash(film: 1, sha256: "00")))
        XCTAssertNil(old(.upNext(name: "x")))
        XCTAssertNil(old(.prefetch(info)))
        XCTAssertNil(old(.nextIn(seconds: 5, name: "x")))
        XCTAssertNil(old(.nextCancel))
    }

    func testVersionNotes() {
        XCTAssertEqual(ControlMessage.protocolVersion, 3)
        XCTAssertEqual(ControlMessage.compatibility(with: 3), .same)
        // 1.2.1 and earlier: the note names what they cannot do.
        for theirs in [1, 2] {
            guard case .note(let text) = ControlMessage.compatibility(with: theirs) else { return XCTFail("no note for \(theirs)") }
            XCTAssertTrue(text.contains("Your partner needs SameSofa 1.3 for rooms without a film"), text)
            let filmless = ControlMessage.oldPartnerNote(theirs: theirs, hasFilm: false)
            XCTAssertTrue(filmless?.hasPrefix("Your partner needs SameSofa 1.3 for rooms without a film") ?? false)
            XCTAssertTrue(ControlMessage.oldPartnerNote(theirs: theirs, hasFilm: true)?.contains("changing film") ?? false)
        }
        XCTAssertNil(ControlMessage.oldPartnerNote(theirs: 3, hasFilm: false))
        guard case .note(let newer) = ControlMessage.compatibility(with: 4) else { return XCTFail("no note for a newer partner") }
        XCTAssertTrue(newer.contains("newer"))
        guard case .incompatible = ControlMessage.compatibility(with: 0) else { return XCTFail("0 must be incompatible") }
        // As 1.2.1 saw a 1.2.0 partner (ours 2): unchanged wording.
        XCTAssertEqual(ControlMessage.compatibility(with: 1, ours: 2), .note("Your partner has an older SameSofa. Some things may not work until they update."))
    }

    func testFilmChannelLabels() {
        XCTAssertTrue(FileInfo.isFilmChannel("file"))
        XCTAssertTrue(FileInfo.isFilmChannel("film-12"))
        XCTAssertFalse(FileInfo.isFilmChannel("control"))
        XCTAssertFalse(FileInfo.isFilmChannel("files"))
    }
}

final class FilmTurnTests: XCTestCase {
    func testGuestMessagesCountOnlyForTheFilmItConfirmed() {
        var turn = FilmTurn()
        XCTAssertFalse(turn.guestIsOnCurrentFilm, "nobody has said hello yet")
        turn.partnerVersion = 3
        XCTAssertFalse(turn.guestIsOnCurrentFilm, "nothing confirmed yet")
        turn.confirm(0)
        XCTAssertTrue(turn.guestIsOnCurrentFilm)
        let first = turn.advance()
        XCTAssertEqual(first, 1)
        XCTAssertFalse(turn.guestIsOnCurrentFilm, "the guest is still on the film before")
        turn.confirm(1)
        XCTAssertTrue(turn.guestIsOnCurrentFilm)
        turn.advance()
        turn.advance()
        turn.confirm(2)
        XCTAssertFalse(turn.guestIsOnCurrentFilm, "a confirmation of a film that is already over")
        turn.confirm(3)
        XCTAssertTrue(turn.guestIsOnCurrentFilm)
        // A new connection: everything has to be confirmed again.
        turn.connectionReset()
        XCTAssertFalse(turn.guestIsOnCurrentFilm)
        XCTAssertEqual(turn.current, 3, "the numbering goes on")
    }

    func testAnOlderGuestOnlyEverHasOneFilm() {
        var turn = FilmTurn()
        turn.advance()
        turn.partnerVersion = 2
        XCTAssertFalse(turn.partnerFollowsChanges)
        XCTAssertTrue(turn.guestIsOnCurrentFilm, "it never confirms anything; its one film is the film")
    }
}

final class NewFilmTimelineTests: XCTestCase {
    func testSequenceNumbersKeepCountingUpward() {
        var host = SyncEngine(role: .host), guest = SyncEngine(role: .guest)
        guest.receive(host.timeline)
        _ = guest.receive(host.play(now: 10))
        let lastOfOldFilm = guest.seek(to: 50, now: 12)
        host.receive(lastOfOldFilm)
        // The film changes.
        let fresh = host.startOver(now: 20)
        XCTAssertFalse(fresh.playing)
        XCTAssertEqual(fresh.position, 0)
        XCTAssertGreaterThanOrEqual(fresh.seq, lastOfOldFilm.seq + SyncEngine.filmGap)
        guest.startOver(at: fresh.seq)
        XCTAssertEqual(guest.timeline.seq, fresh.seq)
        XCTAssertFalse(guest.timeline.playing)
        // The host's first timeline for the new film is the same state: nothing to adopt, nothing lost.
        XCTAssertFalse(guest.receive(fresh))
        // Whatever was sent for the old film, however late and from whichever side, is older than the new film.
        var late = lastOfOldFilm
        for extra in 0..<20 {
            late.seq = lastOfOldFilm.seq + extra
            late.playing = true
            XCTAssertFalse(host.receive(late), "seq \(late.seq) must not apply to the new film")
            late.origin = .host
            XCTAssertFalse(guest.receive(late))
        }
        XCTAssertEqual(host.timeline, fresh)
        // The new film works as usual, from either side.
        let play = guest.play(now: 30)
        XCTAssertEqual(play.seq, fresh.seq + 1)
        XCTAssertTrue(host.receive(play))
    }

    func testStartOverClearsBufferingAndCanPresumeThePartnerIsLoading() {
        var host = SyncEngine(role: .host)
        _ = host.play(now: 1)
        _ = host.setRemoteBuffering(true, now: 2, actualPosition: 1)
        _ = host.setLocalBuffering(true, now: 2, actualPosition: 1)
        host.startOver(now: 5)
        XCTAssertFalse(host.localBuffering)
        XCTAssertFalse(host.remoteBuffering)
        host.startOver(now: 6, partnerLoading: true)
        XCTAssertTrue(host.remoteBuffering)
        // Play pressed while the partner is still loading: held, and released together when they are ready.
        _ = host.play(now: 7)
        XCTAssertTrue(host.isHeld)
        let restart = host.setRemoteBuffering(false, now: 9, actualPosition: 0)
        XCTAssertNotNil(restart)
        XCTAssertTrue(host.effectivePlaying)
    }
}

final class LostTieTests: XCTestCase {
    /// The mechanism behind a press of a button that vanishes: the host changes the timeline by itself (a restart
    /// after buffering, its player slipping) while the guest's command, made from the same starting point, is on its way.
    func testAGuestCommandThatLosesATieIsHandedBack() {
        var host = SyncEngine(role: .host), guest = SyncEngine(role: .guest)
        guest.receive(host.timeline)
        let playing = host.play(now: 10)
        guest.receive(playing)
        // At the same moment: the host re-anchors (automatic), the guest pauses (a person).
        let automatic = host.reanchor(now: 20, actualPosition: 9.8)
        let pause = guest.pause(now: 20, at: 9.9)
        XCTAssertEqual(automatic.seq, pause.seq)
        // The host wins the tie on both sides...
        XCTAssertFalse(host.receive(pause))
        XCTAssertNil(host.takeOverriddenCommand())
        XCTAssertTrue(guest.receive(automatic))
        XCTAssertTrue(guest.timeline.playing, "the pause is gone: this is what 1.2.1 left it at")
        // ...and the guest is told which command to give again.
        XCTAssertEqual(guest.takeOverriddenCommand(), .pause)
        XCTAssertNil(guest.takeOverriddenCommand(), "only once")
        let again = guest.pause(now: 20.05, at: 9.9)
        XCTAssertTrue(host.receive(again))
        XCTAssertFalse(host.timeline.playing)
    }

    func testSeekThatLosesATieKeepsItsTarget() {
        var host = SyncEngine(role: .host), guest = SyncEngine(role: .guest)
        guest.receive(host.timeline)
        guest.receive(host.play(now: 1))
        let restart = host.reanchor(now: 5, actualPosition: 4)
        _ = guest.seek(to: 600, now: 5)
        XCTAssertTrue(guest.receive(restart))
        XCTAssertEqual(guest.takeOverriddenCommand(), .seek(to: 600))
    }

    func testNoHandBackWhenTheOtherSideSawTheCommand() {
        var host = SyncEngine(role: .host), guest = SyncEngine(role: .guest)
        guest.receive(host.timeline)
        guest.receive(host.play(now: 1))
        let pause = guest.pause(now: 5)
        XCTAssertTrue(host.receive(pause))
        // The host presses play afterwards, knowing about the pause: that is simply the newer command.
        let play = host.play(now: 6)
        XCTAssertTrue(guest.receive(play))
        XCTAssertNil(guest.takeOverriddenCommand())
        // And a heartbeat repeating an old timeline is not a tie either.
        XCTAssertFalse(guest.receive(play))
        XCTAssertNil(guest.takeOverriddenCommand())
    }

    func testTheHostNeverLosesATie() {
        var host = SyncEngine(role: .host), guest = SyncEngine(role: .guest)
        guest.receive(host.timeline)
        let hostPause = host.pause(now: 5)
        let guestSeek = guest.seek(to: 100, now: 5)
        XCTAssertFalse(host.receive(guestSeek))
        XCTAssertNil(host.takeOverriddenCommand())
        XCTAssertTrue(guest.receive(hostPause))
        XCTAssertEqual(guest.takeOverriddenCommand(), .seek(to: 100))
    }
}

final class ClockSyncTests: XCTestCase {
    /// True offset 100 s. One-way delay at best 1 ms each way.
    private func exchange(_ clock: inout ClockSync, at t: Double, there: Double, back: Double, hold: Double = 0, sayHold: Bool = true) {
        let t1 = t + there + 100
        let t2 = t + there + hold + back
        clock.add(t0: t, t1: t1, t2: t2, hold: sayHold ? hold : 0)
    }

    func testOneSidedLoadDoesNotShiftTheEstimate() {
        // The film fills the link from host to guest: every reply waits 14 ms or more; pings get through in 1 ms.
        var clock = ClockSync()
        for i in 0..<12 { exchange(&clock, at: Double(i) * 0.25, there: 0.001, back: 0.014 + Double(i % 3) * 0.004) }
        XCTAssertEqual(clock.shortestRoundTripOffset, 100 - 0.0065, accuracy: 0.0002, "1.2.1: off by half the round trip")
        XCTAssertEqual(clock.offset, 100 - 0.0065, accuracy: 0.0002, "nothing better is known yet either")
        // One reply slips through quickly, in an exchange whose ping happened to be slow.
        exchange(&clock, at: 4, there: 0.030, back: 0.001)
        XCTAssertEqual(clock.offset, 100, accuracy: 0.0001, "best ping and best reply come from different exchanges")
        XCTAssertNotEqual(clock.shortestRoundTripOffset, 100, accuracy: 0.004, "the one best exchange is still off")
        XCTAssertEqual(clock.uncertainty ?? 1, 0.001, accuracy: 0.0001)
    }

    func testTheHostHoldingAPingIsNotTakenForDelay() {
        var clock = ClockSync()
        // The host's main thread was busy for 20 ms before it answered, and says so.
        exchange(&clock, at: 0, there: 0.001, back: 0.001, hold: 0.020)
        XCTAssertEqual(clock.offset, 100, accuracy: 0.0001)
        XCTAssertEqual(clock.bestRoundTrip ?? 1, 0.002, accuracy: 0.0001)
        // A host before 1.3 does not say: then it counts as delay on the way back, as it always did.
        var old = ClockSync()
        exchange(&old, at: 0, there: 0.001, back: 0.001, hold: 0.020, sayHold: false)
        XCTAssertEqual(old.offset, 100 - 0.010, accuracy: 0.0001)
    }

    func testWindowForgetsOldSamples() {
        var clock = ClockSync()
        clock.windowSize = 4
        exchange(&clock, at: 0, there: 0.001, back: 0.001)
        for i in 1...4 { exchange(&clock, at: Double(i), there: 0.010, back: 0.002) }
        XCTAssertEqual(clock.offset, 100 + 0.004, accuracy: 0.0001)
    }
}

final class ResumeTests: XCTestCase {
    func testChunkMapSurvivesBeingWrittenDown() {
        var map = ChunkMap(fileSize: 1000 * 64 + 17, chunkSize: 64)
        for index in [0, 1, 2, 63, 64, 65, 500, 999, 1000] { map.mark(index) }
        let restored = ChunkMap(fileSize: map.fileSize, chunkSize: 64, bitmap: map.bitmap)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.receivedCount, 9)
        XCTAssertEqual(restored?.ranges(), map.ranges())
        XCTAssertEqual(restored?.has(1000), true)
        XCTAssertEqual(restored?.has(998), false)
        XCTAssertEqual(map.receivedBytes, 8 * 64 + 17)
        // Not this film's map: wrong length, or chunks beyond the end.
        XCTAssertNil(ChunkMap(fileSize: 10_000, chunkSize: 64, bitmap: map.bitmap))
        var beyond = map.bitmap
        beyond[beyond.count - 1] = 0x80
        XCTAssertNil(ChunkMap(fileSize: map.fileSize, chunkSize: 64, bitmap: beyond))
        // A whole number of words.
        var full = ChunkMap(fileSize: 128 * 10, chunkSize: 10)
        for index in 0..<128 { full.mark(index) }
        XCTAssertEqual(ChunkMap(fileSize: 1280, chunkSize: 10, bitmap: full.bitmap)?.isComplete, true)
    }

    func testForgettingDamagedChunksMakesTheSchedulerAskAgain() {
        var map = ChunkMap(fileSize: 100, chunkSize: 10)
        for index in 0..<10 { map.mark(index) }
        var scheduler = ChunkScheduler(map: map, window: 4)
        XCTAssertEqual(scheduler.nextRequests(), [])
        scheduler.forget([2, 3, 7])
        XCTAssertFalse(scheduler.map.isComplete)
        XCTAssertEqual(scheduler.map.receivedCount, 7)
        XCTAssertEqual(Set(scheduler.nextRequests()), [2, 3, 7])
    }

    func testFingerprint() {
        func bytes(_ size: Int, seed: UInt8) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }
        func print(_ data: Data) -> String {
            FilmFingerprint.compute(size: Int64(data.count)) { offset, length in data.subdata(in: Int(offset)..<Int(offset) + length) }
        }
        let small = bytes(100_000, seed: 1)
        XCTAssertEqual(print(small), print(small))
        XCTAssertNotEqual(print(small), print(bytes(100_000, seed: 2)))
        XCTAssertNotEqual(print(small), print(small + Data([0])), "the size counts")
        // A big file is sampled: first and last block are always in, the samples never run past the end.
        let size: Int64 = 3_000_000_000
        let offsets = FilmFingerprint.sampleOffsets(size: size)
        XCTAssertEqual(offsets.count, FilmFingerprint.blockCount)
        XCTAssertEqual(offsets.first, 0)
        XCTAssertEqual(offsets.last, size - Int64(FilmFingerprint.blockSize))
        XCTAssertEqual(offsets, offsets.sorted())
        XCTAssertTrue(FilmFingerprint.sampleOffsets(size: 0).isEmpty)
        XCTAssertEqual(FilmFingerprint.sampleOffsets(size: 10).count, 1)
        // A different conversion of the same source is a different kept film.
        let a = FilmFingerprint.conversionKey(source: "s", sidecar: nil, arguments: ["-c:v", "copy"], tool: "1")
        XCTAssertEqual(a, FilmFingerprint.conversionKey(source: "s", sidecar: nil, arguments: ["-c:v", "copy"], tool: "1"))
        XCTAssertNotEqual(a, FilmFingerprint.conversionKey(source: "s", sidecar: nil, arguments: ["-c:v", "hevc"], tool: "1"))
        XCTAssertNotEqual(a, FilmFingerprint.conversionKey(source: "s", sidecar: "subs", arguments: ["-c:v", "copy"], tool: "1"))
        XCTAssertNotEqual(a, FilmFingerprint.conversionKey(source: "t", sidecar: nil, arguments: ["-c:v", "copy"], tool: "1"))
        XCTAssertNotEqual(a, FilmFingerprint.conversionKey(source: "s", sidecar: nil, arguments: ["-c:v", "copy"], tool: "2"))
    }

    func testCachePolicy() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func entry(_ id: String, gb: Double, hoursAgo: Double, inUse: Bool = false) -> FilmCachePolicy.Entry {
            .init(id: id, bytes: Int64(gb * Double(1 << 30)), lastUsed: now.addingTimeInterval(-hoursAgo * 3600), inUse: inUse)
        }
        let cap = FilmCachePolicy.defaultCapacity
        XCTAssertEqual(cap, 20 << 30)
        // Nothing to do.
        XCTAssertEqual(FilmCachePolicy.evictions(entries: [entry("a", gb: 5, hoursAgo: 1), entry("b", gb: 5, hoursAgo: 2)], now: now, capacity: cap), [])
        // Older than a day goes, whatever the size.
        XCTAssertEqual(FilmCachePolicy.evictions(entries: [entry("a", gb: 0.1, hoursAgo: 25), entry("b", gb: 5, hoursAgo: 23)], now: now, capacity: cap), ["a"])
        // Over the limit: the least recently used first, only as many as needed.
        let three = [entry("new", gb: 8, hoursAgo: 1), entry("old", gb: 8, hoursAgo: 20), entry("mid", gb: 8, hoursAgo: 10)]
        XCTAssertEqual(FilmCachePolicy.evictions(entries: three, now: now, capacity: cap), ["old"])
        // Room for a film that is about to arrive.
        XCTAssertEqual(FilmCachePolicy.evictions(entries: three, now: now, capacity: cap, incoming: 6 << 30), ["old", "mid"])
        // What is in use stays, even when too old and over the limit.
        let busy = [entry("playing", gb: 15, hoursAgo: 30, inUse: true), entry("other", gb: 4, hoursAgo: 2)]
        XCTAssertEqual(FilmCachePolicy.evictions(entries: busy, now: now, capacity: cap, incoming: 6 << 30), ["other"])
        // A film bigger than the limit is not kept at all; with keeping switched off nothing is.
        XCTAssertFalse(FilmCachePolicy.canKeep(size: 21 << 30, capacity: cap))
        XCTAssertTrue(FilmCachePolicy.canKeep(size: 19 << 30, capacity: cap))
        XCTAssertFalse(FilmCachePolicy.canKeep(size: 1, capacity: 0))
    }
}
