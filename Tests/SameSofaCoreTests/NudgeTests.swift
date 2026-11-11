import XCTest
@testable import SameSofaCore

final class NudgeTests: XCTestCase {
    /// A model of the guest's player and the correction step of PlaybackController.tick.
    struct Guest {
        var engine = SyncEngine(role: .guest)
        var nudge = NudgeState()
        var playerRate = 1.0
        var rateChanges = 0

        mutating func tick(actual: Double, now: Double) {
            switch engine.correction(actualPosition: actual, now: now, nudging: nudge.isNudging) {
            case .none(let rate):
                nudge.reset()
                playerRate = rate
            case .adjustRate(let rate):
                if let speed = nudge.adjust(to: rate) { playerRate = speed; rateChanges += 1 }
            case .seek:
                nudge.reset()
            }
        }

        /// What `apply()` does when a timeline arrives: the player's speed is set afresh.
        mutating func timelineArrived(_ timeline: Timeline) {
            engine.receive(timeline)
            nudge.reset()
            playerRate = timeline.playing ? 1 : 0
        }
    }

    func playing(from position: Double, at now: Double, seq: Int) -> Timeline {
        Timeline(playing: true, position: position, anchor: now, seq: seq, origin: .host)
    }

    func testOneSpeedPerCorrection() {
        var guest = Guest()
        guest.timelineArrived(playing(from: 0, at: 0, seq: 1))
        guest.tick(actual: 10.10, now: 10) // 100 ms ahead
        XCTAssertLessThan(guest.playerRate, 1)
        let chosen = guest.playerRate
        guest.tick(actual: 10.58, now: 10.5) // still ahead, less
        guest.tick(actual: 11.06, now: 11)
        XCTAssertEqual(guest.playerRate, chosen, "the speed chosen at the start is kept")
        XCTAssertEqual(guest.rateChanges, 1)
        guest.tick(actual: 11.51, now: 11.5) // inside the settle band
        XCTAssertEqual(guest.playerRate, 1)
        XCTAssertFalse(guest.nudge.isNudging)
    }

    /// 1.2.0 remembered "a nudge is under way" in a flag that nothing cleared
    /// when a seek set the player back to normal speed, and decided whether
    /// to change speed by comparing with the player's speed. After a seek
    /// during a nudge, being ahead again changed nothing (stale flag, player
    /// at 1.0, wanted below 1.0: "same direction"), and the gap grew until
    /// it was large enough for a visible jump.
    func testSeekDuringANudge() {
        var guest = Guest()
        guest.timelineArrived(playing(from: 0, at: 0, seq: 1))
        guest.tick(actual: 10.10, now: 10)
        XCTAssertTrue(guest.nudge.isNudging)
        // The host seeks while the guest is slowing down.
        guest.timelineArrived(playing(from: 500, at: 12, seq: 2))
        XCTAssertFalse(guest.nudge.isNudging)
        XCTAssertEqual(guest.playerRate, 1)
        // Later the guest is ahead again.
        guest.tick(actual: 520.10, now: 32)
        XCTAssertLessThan(guest.playerRate, 1, "the new gap is corrected")
        XCTAssertEqual(guest.rateChanges, 2)

        // The 1.2.0 rule on the same events: no correction.
        var nudging = false, playerRate = 1.0, corrected = 0
        let engine = guest.engine
        func oldRule(_ actual: Double, _ now: Double) {
            if case .adjustRate(let rate) = engine.correction(actualPosition: actual, now: now, nudging: nudging) {
                if !nudging || (rate > 1) != (playerRate > 1) { nudging = true; playerRate = rate; corrected += 1 }
            }
        }
        nudging = true // left over from the nudge the seek interrupted
        oldRule(520.10, 32)
        XCTAssertEqual(corrected, 0, "this is the defect: ahead by 100 ms and nothing happens")
        XCTAssertEqual(playerRate, 1)
    }

    func testChangeOfDirectionStartsANewCorrection() {
        var nudge = NudgeState()
        XCTAssertEqual(nudge.adjust(to: 0.99), 0.99)
        XCTAssertNil(nudge.adjust(to: 0.995))
        XCTAssertEqual(nudge.adjust(to: 1.004), 1.004)
        nudge.reset()
        XCTAssertEqual(nudge.adjust(to: 1.004), 1.004)
    }

    /// The host is the reference: whatever the gap, the answer for a host is
    /// never applied as a speed (PlaybackController moves the timeline instead).
    func testHostCorrectionsAreNeverASpeedOtherThanZeroOrOne() {
        var host = SyncEngine(role: .host)
        _ = host.play(now: 0)
        for drift in stride(from: -1.0, through: 1.0, by: 0.01) {
            for now in [0.1, 0.34, 0.36, 5, 100] {
                if case .none(let rate) = host.correction(actualPosition: host.targetPosition(at: now) + drift, now: now) {
                    XCTAssertTrue(rate == 0 || rate == 1)
                }
            }
        }
    }
}
