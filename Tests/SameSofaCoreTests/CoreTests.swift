import XCTest
@testable import SameSofaCore

final class RoomCodeTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(RoomCode.normalize("k7m-2pq"), "K7M2PQ")
        XCTAssertEqual(RoomCode.normalize(" K7M 2PQ "), "K7M2PQ")
        XCTAssertNil(RoomCode.normalize("K7M2P"))
        XCTAssertNil(RoomCode.normalize("K7M2PQX"))
        XCTAssertNil(RoomCode.normalize("K7M2P0")) // zero is never used
        XCTAssertEqual(RoomCode.sanitizeTyping("k7-m2pq99"), "K7M2PQ")
        XCTAssertEqual(RoomCode.pretty("K7M2PQ"), "K7M 2PQ")
    }
}

final class MessageTests: XCTestCase {
    func testRoundTrip() {
        let messages: [ControlMessage] = [
            .hello(role: .guest, protocolVersion: 1),
            .fileInfo(FileInfo(size: 123_456_789, name: "Film.mp4", uti: "public.mpeg-4")),
            .want(chunks: [1, 2, 99], urgent: true),
            .progress(fraction: 0.5),
            .timeline(Timeline(playing: true, position: 12.5, anchor: 1000.25, seq: 7, origin: .guest)),
            .heartbeat(Timeline(playing: false, position: 3, anchor: 2, seq: 1, origin: .host), actualPosition: 3.01),
            .buffering(true, position: 12.5),
            .ping(t0: 1.5), .pong(t0: 1.5, t1: 99.25),
            .mediaState(cameraOn: false, micOn: true),
            .bye,
        ]
        for message in messages {
            XCTAssertEqual(ControlMessage.decode(message.encoded()), message)
        }
        XCTAssertNil(ControlMessage.decode(Data("nonsense".utf8)))
    }

    func testFileInfoChunkCount() {
        XCTAssertEqual(FileInfo(size: 0, name: "", uti: "", chunkSize: 10).chunkCount, 0)
        XCTAssertEqual(FileInfo(size: 10, name: "", uti: "", chunkSize: 10).chunkCount, 1)
        XCTAssertEqual(FileInfo(size: 11, name: "", uti: "", chunkSize: 10).chunkCount, 2)
    }
}

final class ChunkTests: XCTestCase {
    func testFrameRoundTrip() {
        let payload = Data((0..<1000).map { UInt8($0 & 0xff) })
        let frame = ChunkFrame.encode(offset: 5_000_000_123, payload: payload)
        let decoded = ChunkFrame.decode(frame)
        XCTAssertEqual(decoded?.offset, 5_000_000_123)
        XCTAssertEqual(decoded.map { Data($0.payload) }, payload)
        XCTAssertNil(ChunkFrame.decode(Data([1, 2, 3])))
    }

    func testChunkMap() {
        var map = ChunkMap(fileSize: 25, chunkSize: 10)
        XCTAssertEqual(map.chunkCount, 3)
        XCTAssertEqual(map.length(ofChunk: 2), 5)
        XCTAssertEqual(map.missing(offset: 0, length: 25), [0, 1, 2])
        XCTAssertTrue(map.mark(0))
        XCTAssertFalse(map.mark(0))
        XCTAssertEqual(map.contiguousBytes(from: 3), 7)
        map.mark(1)
        XCTAssertEqual(map.contiguousBytes(from: 3), 17)
        XCTAssertEqual(map.missing(offset: 5, length: 100), [2])
        map.mark(2)
        XCTAssertTrue(map.isComplete)
        XCTAssertEqual(map.contiguousBytes(from: 20), 5)
        XCTAssertEqual(map.fraction, 1)
    }

    /// Simulates a whole transfer with shuffled delivery and checks the
    /// reassembled bytes are identical.
    func testReassemblyIsByteExact() {
        let size = 1_000_003
        var rng = SystemRandomNumberGenerator()
        let source = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let chunk = 4096
        var scheduler = ChunkScheduler(map: ChunkMap(fileSize: Int64(size), chunkSize: chunk), window: 32)
        var sink = Data(count: size)
        var rounds = 0
        while !scheduler.map.isComplete {
            rounds += 1
            XCTAssertLessThan(rounds, 10_000)
            var requests = scheduler.nextRequests()
            XCTAssertLessThanOrEqual(scheduler.inFlight.count, 32)
            requests.shuffle()
            if rounds == 3 { scheduler.prioritize(offset: 600_000, length: 10_000) }
            for index in requests {
                let start = index * chunk
                let end = min(size, start + chunk)
                let frame = ChunkFrame.encode(offset: Int64(start), payload: source[start..<end])
                guard let (offset, payload) = ChunkFrame.decode(frame) else { return XCTFail() }
                sink.replaceSubrange(Int(offset)..<Int(offset) + payload.count, with: payload)
                scheduler.received(index)
            }
        }
        XCTAssertEqual(sink, source)
    }

    func testSchedulerOrder() {
        var scheduler = ChunkScheduler(map: ChunkMap(fileSize: 100 * 10, chunkSize: 10), window: 6)
        scheduler.tailChunks = 2
        // Tail first (for MP4 indexes at the end), then from the playhead.
        XCTAssertEqual(scheduler.nextRequests(), [98, 99, 0, 1, 2, 3])
        // A player request jumps the queue once there is room.
        scheduler.prioritize(offset: 500, length: 25)
        XCTAssertTrue(scheduler.hasUrgent)
        scheduler.received(98)
        scheduler.received(99)
        XCTAssertEqual(scheduler.nextRequests(), [50, 51])
        for index in [0, 1, 2, 3, 50, 51] { scheduler.received(index) }
        scheduler.setPlayhead(offset: 700)
        XCTAssertEqual(scheduler.nextRequests(), [52, 70, 71, 72, 73, 74])
    }
}

final class SyncTests: XCTestCase {
    func testClockSyncPrefersShortestRoundTrip() {
        var clock = ClockSync()
        // True offset +100. A slow sample with asymmetric delay is ignored.
        clock.add(t0: 0, t1: 100.4, t2: 0.5)    // rtt 0.5, est 100.15
        clock.add(t0: 1, t1: 101.01, t2: 1.02)  // rtt 0.02, est 100.0
        clock.add(t0: 2, t1: 102.3, t2: 2.4)    // rtt 0.4
        XCTAssertEqual(clock.offset, 100.0, accuracy: 0.001)
        XCTAssertEqual(clock.bestRoundTrip ?? -1, 0.02, accuracy: 1e-9)
    }

    func testTimeline() {
        let t = Timeline(playing: true, position: 10, anchor: 100, seq: 1, origin: .host)
        XCTAssertEqual(t.expectedPosition(at: 99), 10)  // scheduled start not reached yet
        XCTAssertEqual(t.expectedPosition(at: 105), 15)
        let paused = Timeline(playing: false, position: 10, anchor: 100, seq: 1, origin: .host)
        XCTAssertEqual(paused.expectedPosition(at: 500), 10)
    }

    func testPlayPauseSeekPropagateBothWays() {
        var host = SyncEngine(role: .host)
        var guest = SyncEngine(role: .guest)
        guest.receive(host.timeline)
        // Guest presses play.
        let play = guest.play(now: 0)
        XCTAssertTrue(host.receive(play))
        XCTAssertEqual(host.timeline, guest.timeline)
        XCTAssertTrue(host.effectivePlaying)
        // Host pauses 10 s later.
        let pause = host.pause(now: 10)
        XCTAssertTrue(guest.receive(pause))
        XCTAssertFalse(guest.timeline.playing)
        XCTAssertEqual(guest.timeline.position, 10 - host.startLead, accuracy: 1e-9)
        // Guest seeks.
        let seek = guest.seek(to: 42, now: 11)
        XCTAssertTrue(host.receive(seek))
        XCTAssertEqual(host.targetPosition(at: 50), 42)
        // A stale message is ignored.
        XCTAssertFalse(host.receive(play))
    }

    func testSimultaneousPressesConverge() {
        var host = SyncEngine(role: .host)
        var guest = SyncEngine(role: .guest)
        XCTAssertTrue(guest.receive(host.timeline)) // first heartbeat
        let a = host.play(now: 0)
        let b = guest.seek(to: 30, now: 0)
        XCTAssertEqual(a.seq, b.seq)
        host.receive(b)
        guest.receive(a)
        // Same sequence number: the host's command wins on both sides.
        XCTAssertEqual(host.timeline, guest.timeline)
        XCTAssertEqual(host.timeline.origin, .host)
    }

    func testCorrections() {
        var engine = SyncEngine(role: .guest)
        engine.receive(Timeline(playing: true, position: 0, anchor: 0, seq: 1, origin: .host))
        XCTAssertEqual(engine.correction(actualPosition: 10.02, now: 10), .none(rate: 1))
        guard case .adjustRate(let slower) = engine.correction(actualPosition: 10.2, now: 10) else { return XCTFail() }
        XCTAssertLessThan(slower, 1)
        XCTAssertGreaterThanOrEqual(slower, 0.99, "never more than 1 % off normal speed")
        guard case .adjustRate(let faster) = engine.correction(actualPosition: 9.8, now: 10) else { return XCTFail() }
        XCTAssertGreaterThan(faster, 1)
        XCTAssertLessThanOrEqual(faster, 1.01)
        // A gap just over the deadband gets a gentler nudge than a big one.
        guard case .adjustRate(let gentle) = engine.correction(actualPosition: 9.93, now: 10) else { return XCTFail() }
        XCTAssertLessThan(gentle, faster)
        XCTAssertGreaterThanOrEqual(gentle, 1 + engine.minRateDelta)
        // Too far for a nudge of that size to be brief: seek.
        XCTAssertEqual(engine.correction(actualPosition: 9.5, now: 10), .seek(to: 10))
        XCTAssertEqual(engine.correction(actualPosition: 5, now: 10), .seek(to: 10))
    }

    func testNudgeContinuesUntilSettled() {
        var engine = SyncEngine(role: .guest)
        engine.receive(Timeline(playing: true, position: 0, anchor: 0, seq: 1, origin: .host))
        // 40 ms off: inside the deadband, so no nudge starts...
        XCTAssertEqual(engine.correction(actualPosition: 10.04, now: 10), .none(rate: 1))
        // ...but one that is under way carries on until the gap is really closed,
        guard case .adjustRate = engine.correction(actualPosition: 10.04, now: 10, nudging: true) else { return XCTFail() }
        // and then stops at exactly normal speed.
        XCTAssertEqual(engine.correction(actualPosition: 10.01, now: 10, nudging: true), .none(rate: 1))
    }

    func testHostMovesTheTimelineInsteadOfChangingSpeed() {
        var host = SyncEngine(role: .host)
        _ = host.play(now: 0)
        let before = host.timeline
        // The host's player slipped 0.1 s behind.
        let now = 20.0, actual = host.targetPosition(at: now) - 0.1
        let moved = host.reanchor(now: now, actualPosition: actual)
        XCTAssertTrue(moved.isNewer(than: before))
        XCTAssertTrue(moved.playing)
        XCTAssertEqual(host.correction(actualPosition: actual, now: now), .none(rate: 1))
        XCTAssertEqual(host.targetPosition(at: now + 5), actual + 5, accuracy: 1e-9)
        var guest = SyncEngine(role: .guest)
        XCTAssertTrue(guest.receive(moved))
    }

    /// Simulates two players with slightly different clocks and speeds and
    /// checks the controller keeps them within a quarter of a second.
    func testDriftStaysWithinTolerance() {
        var engine = SyncEngine(role: .guest)
        engine.receive(Timeline(playing: true, position: 0, anchor: 0, seq: 1, origin: .host))
        var position = 0.4 // starts 0.4 s behind
        var rate = 1.0
        let naturalSpeed = 1.002 // this machine's player runs 0.2% fast
        var worst = 0.0
        var t = 0.0
        while t < 600 {
            switch engine.correction(actualPosition: position, now: t) {
            case .none(let r): rate = r
            case .adjustRate(let r): rate = r
            case .seek(let p): position = p
            }
            t += 0.5
            position += 0.5 * rate * naturalSpeed
            if t > 20 { worst = max(worst, abs(position - t)) }
        }
        XCTAssertLessThan(worst, 0.25)
    }

    func testBufferingHoldsAndHostRestarts() {
        var host = SyncEngine(role: .host)
        var guest = SyncEngine(role: .guest)
        guest.receive(host.play(now: 0))
        // Guest starves at t=20.
        XCTAssertNil(guest.setLocalBuffering(true, now: 20, actualPosition: 19.5))
        XCTAssertNil(host.setRemoteBuffering(true, now: 20.05, actualPosition: 19.7))
        XCTAssertFalse(host.effectivePlaying)
        XCTAssertEqual(host.targetPosition(at: 30), 19.7, accuracy: 1e-9)
        // Guest recovers: only the host issues the restart.
        XCTAssertNil(guest.setLocalBuffering(false, now: 25, actualPosition: 19.5))
        XCTAssertFalse(guest.effectivePlaying) // still waiting for the host's restart
        XCTAssertTrue(guest.awaitingRestart)
        guard let restart = host.setRemoteBuffering(false, now: 25.05, actualPosition: 19.7) else { return XCTFail() }
        XCTAssertTrue(restart.playing)
        XCTAssertTrue(guest.receive(restart))
        XCTAssertTrue(guest.effectivePlaying)
    }
}
