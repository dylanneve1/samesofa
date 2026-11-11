import XCTest
@testable import SameSofaCore

/// The repair of a film's last frames (TimestampTail): time bases, start
/// offsets, uneven frame durations, and the check that refuses a wrong repair.
final class TimestampTailTests: XCTestCase {
    typealias Sample = TimestampTail.Sample

    /// A film as dts2pts would repair it if it knew the whole file: `display[r]`
    /// is the decode position of the picture shown r-th, decode times `dts`.
    func repaired(dts: [Int64], display: [Int], delay: Int) -> [Sample] {
        let last = dts.count - 1, step = dts[last] - dts[last - 1]
        var samples = dts.map { Sample(pts: 0, dts: $0) }
        for (rank, decodePosition) in display.enumerated() {
            let slot = rank + delay
            samples[decodePosition].pts = slot <= last ? dts[slot] : dts[last] + Int64(slot - last) * step
        }
        return samples
    }

    /// Decode positions in display order for a stream of I b b P groups (two B-frames, pyramid off).
    func displayOrder(frames: Int) -> [Int] {
        // Decode order: I P b b P b b ...; display: I b b P b b P ...
        var order = [0]
        var next = 1
        while next < frames {
            let p = next, bs = [next + 1, next + 2].filter { $0 < frames }
            order += bs + [p]
            next += 3
        }
        return order
    }

    func testDelayIsCountedInFrames() {
        let dts = (0..<48).map { Int64($0 * 1001 - 2002) }
        let film = repaired(dts: dts, display: displayOrder(frames: 48), delay: 2)
        XCTAssertEqual(TimestampTail.reorderDelay(head: film), 2)
        XCTAssertEqual(TimestampTail.reorderDelay(head: Array(film.prefix(20))), 2, "a short head is enough")
        XCTAssertNil(TimestampTail.reorderDelay(head: Array(film.prefix(3))))
        // Not a dts2pts result: presentation times that are no decode times.
        XCTAssertNil(TimestampTail.reorderDelay(head: dts.map { Sample(pts: $0 + 7, dts: $0) }))
        // Decode times that step back.
        XCTAssertNil(TimestampTail.reorderDelay(head: [Sample(pts: 0, dts: 0), Sample(pts: 2, dts: 1), Sample(pts: 1, dts: 1), Sample(pts: 3, dts: 3)]))
    }

    /// Time bases of real containers, with the frame durations they give 24000/1001 fps.
    func testTimeBases() {
        let cases: [(name: String, ticksPerSecond: Double)] = [
            ("1/1000", 1000), ("1/600", 600), ("1/24000", 24_000), ("1/90000", 90_000), ("1/1200000", 1_200_000),
        ]
        for c in cases {
            // Rounded decode times: at 1/1000 and 1/600 the durations are uneven (41/42 ms, 25/26 ticks).
            let dts = (0..<96).map { Int64((Double($0 - 2) * 1001 / 24_000 * c.ticksPerSecond).rounded()) }
            let order = displayOrder(frames: 96)
            let truth = repaired(dts: dts, display: order, delay: 2)
            XCTAssertEqual(TimestampTail.reorderDelay(head: Array(truth.prefix(48))), 2, c.name)
            // What the tail probe sees: the last 40 pictures in display order, as decode times.
            let window = order.filter { $0 >= 56 }.map { dts[$0] }
            let corrections = TimestampTail.corrections(outputOrder: window, delayFrames: 2, count: 12)
            XCTAssertEqual(corrections.count, 12, c.name)
            for correction in corrections {
                let position = dts.firstIndex(of: correction.decodeTime)!
                XCTAssertEqual(correction.presentationTime, truth[position].pts, "\(c.name): sample \(position)")
            }
            XCTAssertTrue(TimestampTail.tailIsConsistent(Array(truth.suffix(40))), c.name)
        }
    }

    func testUnevenFrameDurations() {
        // Variable frame rate: 40 ms frames, then 20 ms frames towards the end.
        var dts: [Int64] = [], t: Int64 = -80
        for i in 0..<60 { dts.append(t); t += i < 30 ? 40 : 20 }
        let order = displayOrder(frames: 60)
        let truth = repaired(dts: dts, display: order, delay: 2)
        XCTAssertEqual(TimestampTail.reorderDelay(head: Array(truth.prefix(40))), 2)
        let corrections = TimestampTail.corrections(outputOrder: order.filter { $0 >= 30 }.map { dts[$0] }, delayFrames: 2, count: 12)
        for correction in corrections {
            XCTAssertEqual(correction.presentationTime, truth[dts.firstIndex(of: correction.decodeTime)!].pts)
        }
        XCTAssertTrue(TimestampTail.tailIsConsistent(Array(truth.suffix(30))))
    }

    /// The real file behind the repair: 24000/1001 fps at 1/1200000, first samples -100099, -50050, 0, 50050.
    func testStartOffsetsDoNotMatter() {
        let tail = [TimestampTail.Correction(decodeTime: 8_349_591_250, presentationTime: 8_349_691_350)]
        XCTAssertEqual(TimestampTail.bitstreamFilter(tail: tail, firstDecodeTime: -100_099),
                       "dts2pts,setts=pts=if(eq(DTS-STARTDTS\\,8349691349)\\,STARTDTS+(8349791449)\\,PTS)")
        // The same film stored five seconds later: identical filter, because
        // only distances from the first sample are used.
        let shifted = [TimestampTail.Correction(decodeTime: 8_349_591_250 + 6_000_000, presentationTime: 8_349_691_350 + 6_000_000)]
        XCTAssertEqual(TimestampTail.bitstreamFilter(tail: shifted, firstDecodeTime: -100_099 + 6_000_000),
                       TimestampTail.bitstreamFilter(tail: tail, firstDecodeTime: -100_099))
        XCTAssertEqual(TimestampTail.bitstreamFilter(tail: tail, firstDecodeTime: nil), "dts2pts")
    }

    func testFewFrames() {
        XCTAssertTrue(TimestampTail.corrections(outputOrder: [], delayFrames: 2, count: 12).isEmpty)
        XCTAssertTrue(TimestampTail.corrections(outputOrder: [5], delayFrames: 2, count: 12).isEmpty)
        XCTAssertEqual(TimestampTail.corrections(outputOrder: [0, 20, 10], delayFrames: 1, count: 12).map(\.presentationTime), [10, 30, 20])
        XCTAssertFalse(TimestampTail.tailIsConsistent([]))
        XCTAssertFalse(TimestampTail.tailIsConsistent([Sample(pts: 0, dts: 0), Sample(pts: 1, dts: 1), Sample(pts: 2, dts: 2)]))
    }

    /// The validation must refuse every kind of wrong tail.
    func testWrongRepairsAreRefused() {
        let dts = (0..<60).map { Int64($0 * 50_050 - 100_100) }
        let order = displayOrder(frames: 60)
        let truth = repaired(dts: dts, display: order, delay: 2)
        XCTAssertTrue(TimestampTail.tailIsConsistent(truth))
        XCTAssertTrue(TimestampTail.tailIsConsistent(Array(truth.suffix(24))))

        // 1. The tail as dts2pts leaves it: the last pictures share a time.
        var madeUp = truth
        madeUp[58].pts = madeUp[57].pts
        XCTAssertFalse(TimestampTail.tailIsConsistent(madeUp), "repeated presentation time")
        // 2. Corrections applied to the wrong samples (two pictures swap times): every time is
        // still used once, so this is the decoder-order check's to catch.
        var swapped = truth
        (swapped[order[58]].pts, swapped[order[59]].pts) = (swapped[order[59]].pts, swapped[order[58]].pts)
        let inDisplayOrder = { (film: [Sample]) in order.map { String(film[$0].pts) }.joined(separator: "\n") }
        XCTAssertEqual(TimestampReport.parse(ffprobeFrameTimes: inDisplayOrder(truth), repeatsCount: true).backwardSteps, 0)
        XCTAssertGreaterThan(TimestampReport.parse(ffprobeFrameTimes: inDisplayOrder(swapped), repeatsCount: true).backwardSteps, 0)
        // 3. The last pictures one frame late: in order, no repeats, but a hole before them.
        var late = truth
        for rank in 48..<60 { late[order[rank]].pts += 50_050 }
        XCTAssertEqual(Set(late.map(\.pts)).count, 60, "no repeats in this one")
        XCTAssertEqual(TimestampReport.parse(ffprobeFrameTimes: inDisplayOrder(late), repeatsCount: true).backwardSteps, 0, "and in order")
        XCTAssertFalse(TimestampTail.tailIsConsistent(late), "hole in the presentation times")
        // 4. One tick off (the rounding that a start offset in microseconds can cause at 1/1200000).
        var tick = truth
        tick[order[59]].pts += 1
        XCTAssertFalse(TimestampTail.tailIsConsistent(tick), "one tick off")
        // 5. Presentation before decode.
        var early = truth
        early[59].pts = early[59].dts - 1
        XCTAssertFalse(TimestampTail.tailIsConsistent(early))
        // The decoder-order check counts repeats when asked to.
        XCTAssertEqual(TimestampReport.parse(ffprobeFrameTimes: "1\n2\n2\n3\n").backwardSteps, 0)
        XCTAssertEqual(TimestampReport.parse(ffprobeFrameTimes: "1\n2\n2\n3\n", repeatsCount: true).backwardSteps, 1)
    }
}
