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
    public static func parse(ffprobeFrameTimes text: String) -> TimestampReport {
        var report = TimestampReport(frames: 0, backwardSteps: 0)
        var previous: Int64?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let field = line.split(separator: ",").first, let pts = Int64(field) else { continue }
            report.frames += 1
            if let previous, pts < previous { report.backwardSteps += 1 }
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
/// FFmpeg's dts2pts filter gives each picture the decode time of a later
/// sample; for the very last pictures there is no later sample, and it makes
/// their times up. They are computed here instead, from the order in which
/// the decoder puts the last pictures out.
public struct TimestampTail: Equatable, Sendable {
    public struct Correction: Equatable, Sendable {
        public var decodeTime: Int64
        public var presentationTime: Int64
        public init(decodeTime: Int64, presentationTime: Int64) {
            self.decodeTime = decodeTime
            self.presentationTime = presentationTime
        }
    }

    /// `outputOrder`: decode times of the film's last pictures in the order
    /// the decoder displays them (the end of the film must be the end of the
    /// list). `delay`: presentation minus decode time of a picture that is
    /// displayed in the same position it is decoded in (the reorder delay).
    /// Returns corrections for the last `count` samples in decode order.
    public static func corrections(outputOrder: [Int64], delay: Int64, count: Int) -> [Correction] {
        guard outputOrder.count >= 2, Set(outputOrder).count == outputOrder.count else { return [] }
        let decodeOrder = outputOrder.sorted()
        // The picture displayed j-th takes the j-th decode slot (plus the delay).
        var presentation: [Int64: Int64] = [:]
        for (position, decodeTime) in outputOrder.enumerated() {
            presentation[decodeTime] = decodeOrder[position] + delay
        }
        return decodeOrder.suffix(count).compactMap { decodeTime in
            presentation[decodeTime].map { Correction(decodeTime: decodeTime, presentationTime: $0) }
        }
    }

    /// The FFmpeg bitstream filter chain for a repair: dts2pts, then the tail.
    public static func bitstreamFilter(tail: [Correction]) -> String {
        guard !tail.isEmpty else { return "dts2pts" }
        var expression = "PTS"
        for correction in tail.reversed() {
            expression = "if(eq(DTS\\,\(correction.decodeTime))\\,\(correction.presentationTime)\\,\(expression))"
        }
        return "dts2pts,setts=pts=\(expression)"
    }
}
