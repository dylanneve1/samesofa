import Foundation

// Some MP4 files carry video with B-frames but no reordering information:
// every sample's presentation time equals its decode time. Players that
// order pictures by the bitstream (FFmpeg-based ones) show them fine;
// AVFoundation trusts the container and shows the frames in decode order,
// which looks like the picture jumping back and forth. The check below
// reads what FFmpeg's decoder reports; the repair (FFmpeg's dts2pts filter)
// rebuilds the presentation times from the bitstream's picture order
// without re-encoding.

/// Result of decoding a few short stretches of the film with FFmpeg.
public struct TimestampReport: Equatable, Sendable {
    /// Decoded frames looked at.
    public var frames: Int
    /// Frames the decoder put out after a frame with a later presentation
    /// time: in a healthy file this never happens.
    public var backwardSteps: Int

    public init(frames: Int, backwardSteps: Int) {
        self.frames = frames
        self.backwardSteps = backwardSteps
    }

    /// The container's presentation times contradict the bitstream's picture order.
    public var isDamaged: Bool { frames >= 12 && backwardSteps > max(2, frames / 50) }

    /// `text`: output of `ffprobe -show_entries frame=pts -of csv=p=0`, one
    /// decoded frame per line in the decoder's output (display) order. The
    /// stretches must be listed from the start of the film towards the end.
    /// `repeatsCount`: a frame with the same time as the one before it also
    /// counts (for checking a single stretch of a repaired file).
    public static func parse(ffprobeFrameTimes text: String, repeatsCount: Bool = false) -> TimestampReport {
        var report = TimestampReport(frames: 0, backwardSteps: 0)
        var previous: Int64?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let field = line.split(separator: ",").first, let pts = Int64(field) else { continue }
            report.frames += 1
            if let previous, pts < previous || (repeatsCount && pts == previous) { report.backwardSteps += 1 }
            previous = pts
        }
        return report
    }
}

/// Sanity of the samples in a (repaired) file.
public struct PacketTimesReport: Equatable, Sendable {
    public var packets = 0
    public var presentationBeforeDecode = 0
    public var duplicatePresentationTimes = 0
    public var decodeTimeNotIncreasing = 0
    /// Largest presentation - decode distance, in decode steps.
    public var largestReorder = 0.0

    public var isSane: Bool {
        packets > 0 && presentationBeforeDecode == 0 && duplicatePresentationTimes == 0 && decodeTimeNotIncreasing == 0
    }

    /// `text`: output of `ffprobe -show_entries packet=pts,dts -of csv=p=0` for one stretch.
    public static func parse(ffprobePacketTimes text: String) -> PacketTimesReport {
        var report = PacketTimesReport()
        var seen = Set<Int64>()
        var previousDTS: Int64?
        var steps: [Int64] = []
        var distances: [Int64] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2, let pts = Int64(fields[0]), let dts = Int64(fields[1]) else { continue }
            report.packets += 1
            if pts < dts { report.presentationBeforeDecode += 1 }
            if !seen.insert(pts).inserted { report.duplicatePresentationTimes += 1 }
            if let previousDTS {
                if dts <= previousDTS { report.decodeTimeNotIncreasing += 1 } else { steps.append(dts - previousDTS) }
            }
            previousDTS = dts
            distances.append(pts - dts)
        }
        if let step = steps.sorted().dropFirst(steps.count / 2).first, step > 0, let far = distances.max() {
            report.largestReorder = Double(far) / Double(step)
        }
        return report
    }
}

/// Presentation times for the last few samples of a film.
///
/// FFmpeg's dts2pts filter gives the picture displayed in position r the
/// decode time of the sample `delay` places further on; for the very last
/// pictures there is no such sample, and it makes their times up. They are
/// computed here instead, from the order in which the decoder puts the last
/// pictures out.
public struct TimestampTail: Equatable, Sendable {
    public struct Correction: Equatable, Sendable {
        public var decodeTime: Int64
        public var presentationTime: Int64
        public init(decodeTime: Int64, presentationTime: Int64) {
            self.decodeTime = decodeTime
            self.presentationTime = presentationTime
        }
    }

    /// One sample: presentation and decode time in the same time base.
    public struct Sample: Equatable, Sendable {
        public var pts: Int64
        public var dts: Int64
        public init(pts: Int64, dts: Int64) {
            self.pts = pts
            self.dts = dts
        }
    }

    /// The reorder delay dts2pts uses, in frames, read off the first samples
    /// (in decode order) of a copy it has already repaired: the picture
    /// displayed in position r carries the decode time of sample r + delay.
    /// Counting frames instead of ticks keeps this right when frame
    /// durations vary. nil when the samples do not follow that rule.
    public static func reorderDelay(head: [Sample]) -> Int? {
        let decode = head.map(\.dts)
        guard head.count >= 4, zip(decode, decode.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        var slot: [Int64: Int] = [:]
        for (index, time) in decode.enumerated() { slot[time] = index }
        let display = head.map(\.pts).sorted()
        guard Set(display).count == display.count else { return nil }
        var delay: Int?, agreeing = 0
        for (rank, time) in display.enumerated() {
            // Pictures displayed later take decode times beyond the samples read.
            guard let index = slot[time] else { break }
            if let delay, delay != index - rank { return nil }
            delay = index - rank
            agreeing += 1
        }
        guard let delay, delay >= 0, delay <= 16, agreeing >= 3 else { return nil }
        return delay
    }

    /// `outputOrder`: decode times of the film's last pictures in the order
    /// the decoder displays them (the end of the film must be the end of the
    /// list). `delayFrames`: see `reorderDelay`. Returns corrections for the
    /// last `count` samples in decode order. Pictures whose slot lies beyond
    /// the last sample continue at the spacing of the last two samples.
    public static func corrections(outputOrder: [Int64], delayFrames: Int, count: Int) -> [Correction] {
        guard outputOrder.count >= 2, delayFrames >= 0, Set(outputOrder).count == outputOrder.count else { return [] }
        let decodeOrder = outputOrder.sorted()
        let last = decodeOrder.count - 1
        let step = decodeOrder[last] - decodeOrder[last - 1]
        guard step > 0 else { return [] }
        var presentation: [Int64: Int64] = [:]
        for (position, decodeTime) in outputOrder.enumerated() {
            let slot = position + delayFrames
            presentation[decodeTime] = slot <= last ? decodeOrder[slot] : decodeOrder[last] + Int64(slot - last) * step
        }
        return decodeOrder.suffix(count).compactMap { decodeTime in
            presentation[decodeTime].map { Correction(decodeTime: decodeTime, presentationTime: $0) }
        }
    }

    /// The FFmpeg bitstream filter chain for a repair: dts2pts, then the tail.
    ///
    /// `firstDecodeTime` is the decode time, as it is stored in the file, of
    /// the first sample FFmpeg copies. FFmpeg moves every timestamp by the
    /// file's start time before the filters see it, so the samples are
    /// recognised by their distance from the first one, never by the stored
    /// value itself. Without it only dts2pts runs (and the result is left to
    /// the validation).
    public static func bitstreamFilter(tail: [Correction], firstDecodeTime: Int64? = nil) -> String {
        guard !tail.isEmpty, let base = firstDecodeTime else { return "dts2pts" }
        var expression = "PTS"
        for correction in tail.reversed() {
            expression = "if(eq(DTS-STARTDTS\\,\(correction.decodeTime - base))\\,STARTDTS+(\(correction.presentationTime - base))\\,\(expression))"
        }
        return "dts2pts,setts=pts=\(expression)"
    }

    /// Check of a repaired file's last samples (any order): every
    /// presentation time is used once, none lies before its decode time, and
    /// the last `window` of them are exactly the decode times moved on by
    /// the reorder delay, continuing at the last spacing. A tail that was
    /// left as dts2pts made it up, or corrected for the wrong samples, fails.
    public static func tailIsConsistent(_ samples: [Sample], window: Int = 16) -> Bool {
        let count = samples.count
        guard count >= 4, samples.allSatisfy({ $0.pts >= $0.dts }) else { return false }
        let decode = samples.map(\.dts).sorted(), display = samples.map(\.pts).sorted()
        guard Set(decode).count == count, Set(display).count == count else { return false }
        let last = count - 1
        let step = decode[last] - decode[last - 1]
        guard step > 0, let delay = (0...min(16, last)).first(where: { display[last - $0] == decode[last] }) else { return false }
        for position in max(0, count - window)...last {
            let slot = position + delay
            let expected = slot <= last ? decode[slot] : decode[last] + Int64(slot - last) * step
            if display[position] != expected { return false }
        }
        return true
    }
}
