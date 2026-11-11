import Foundation

/// One display mode, reduced to the numbers the planner needs.
public struct DisplayModeInfo: Equatable, Sendable {
    /// Position in the list the mode came from (maps back to the system mode).
    public var index: Int
    /// Size in points.
    public var width: Int
    public var height: Int
    /// Size in pixels (differs from points on HiDPI modes).
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Refresh rate in Hz. 0 means the system did not say.
    public var refreshRate: Double
    public var usableForDesktop: Bool

    public init(index: Int, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int,
                refreshRate: Double, usableForDesktop: Bool) {
        self.index = index
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.usableForDesktop = usableForDesktop
    }

    /// True when both modes have the same size and scaling (refresh rate may differ).
    public func sameGeometry(as other: DisplayModeInfo) -> Bool {
        width == other.width && height == other.height
            && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
    }
}

/// Decides whether and how to change the display refresh rate for a film.
///
/// Three grades of fit between a refresh rate and a film's frame rate:
/// precise (a whole multiple: 23.976 fps on 47.952 or 119.88 Hz), exact (a
/// whole multiple but for the 1000/1001 difference between film and video
/// rates: 23.976 fps on 24 or 120 Hz, one repeated frame every 42 seconds)
/// and even (within 1 %). A display that is already exact is left alone:
/// changing the mode blanks many displays for a moment, which is worse than
/// one repeated frame every 42 seconds.
public enum DisplayModePlanner {
    /// This close to a whole multiple of the film rate is "precise".
    public static let preciseTolerance = 0.0003
    /// This close is "exact" (covers the 1000/1001 difference).
    public static let exactTolerance = 0.0015
    /// This close counts as "even" (same rule as `FrameRateMatch.isEvenCadence`).
    public static let evenTolerance = 0.01

    /// How far the refresh rate is from a whole multiple of the film rate, as a fraction.
    /// nil when the refresh rate is lower than the film rate or either value is unusable.
    public static func cadenceError(filmFrameRate: Double, refreshRate: Double) -> Double? {
        guard filmFrameRate >= 1, refreshRate >= 1 else { return nil }
        guard refreshRate >= filmFrameRate * 0.99 else { return nil }
        let ratio = refreshRate / filmFrameRate
        let whole = ratio.rounded()
        guard whole >= 1 else { return nil }
        return abs(ratio - whole) / whole
    }

    /// 0 precise, 1 exact, 2 even, 3 uneven (judder) or unusable.
    static func grade(filmFrameRate: Double, refreshRate: Double) -> Int {
        guard let error = cadenceError(filmFrameRate: filmFrameRate, refreshRate: refreshRate) else { return 3 }
        return error <= preciseTolerance ? 0 : error <= exactTolerance ? 1 : error <= evenTolerance ? 2 : 3
    }

    /// True when every frame is shown for the same number of refreshes.
    public static func isEven(filmFrameRate: Double, refreshRate: Double) -> Bool {
        grade(filmFrameRate: filmFrameRate, refreshRate: refreshRate) <= 2
    }

    /// The mode to switch to, or nil when the display should be left alone.
    /// Only modes with exactly the current size and scaling are considered.
    /// The best grade wins; among equals the highest refresh rate (smoother
    /// pointer and controls), then the earlier entry of the list.
    public static func bestMode(filmFrameRate: Double, current: DisplayModeInfo,
                                available: [DisplayModeInfo], variableRefresh: Bool) -> DisplayModeInfo? {
        guard filmFrameRate >= 1, !variableRefresh, current.refreshRate >= 1 else { return nil }
        let currentGrade = grade(filmFrameRate: filmFrameRate, refreshRate: current.refreshRate)
        guard currentGrade >= 2 else { return nil }

        var candidates: [(mode: DisplayModeInfo, grade: Int)] = []
        for mode in available {
            guard mode.sameGeometry(as: current), mode.usableForDesktop, mode.refreshRate >= 1,
                  abs(mode.refreshRate - current.refreshRate) > 0.01 else { continue }
            let modeGrade = grade(filmFrameRate: filmFrameRate, refreshRate: mode.refreshRate)
            // From judder any even mode is better; an even display only moves for an exact one.
            guard modeGrade < currentGrade, modeGrade <= 2 else { continue }
            candidates.append((mode, modeGrade))
        }
        let sorted = candidates.sorted { a, b in
            if a.grade != b.grade { return a.grade < b.grade }
            if a.mode.refreshRate != b.mode.refreshRate { return a.mode.refreshRate > b.mode.refreshRate }
            return a.mode.index < b.mode.index
        }
        return sorted.first?.mode
    }

    /// One plain sentence describing how the film will be shown.
    public static func describe(filmFrameRate: Double, refreshRate: Double,
                                variableRefresh: Bool, switched: Bool) -> String {
        let film = formatNumber(filmFrameRate, maxDecimals: 3)
        if variableRefresh {
            return "\(film) fps on a variable-refresh display: every frame is shown for the same time."
        }
        let hz = formatNumber(refreshRate, maxDecimals: 2)
        guard let error = cadenceError(filmFrameRate: filmFrameRate, refreshRate: refreshRate) else {
            return "\(film) fps on \(hz) Hz: the display is slower than the film, so frames are skipped."
        }
        if error <= evenTolerance {
            let suffix = switched ? " (display matched to the film)" : ""
            return "\(film) fps on \(hz) Hz\(suffix): every frame is shown for the same time."
        }
        let ratio = refreshRate / filmFrameRate
        let low = Int(ratio.rounded(.down))
        if low >= 1 {
            return "\(film) fps on \(hz) Hz: frames alternate between \(low) and \(low + 1) refreshes (judder)."
        }
        return "\(film) fps on \(hz) Hz: frames are shown for uneven times (judder)."
    }

    /// Up to `maxDecimals` decimals, no trailing zeros.
    public static func formatNumber(_ value: Double, maxDecimals: Int) -> String {
        var text = String(format: "%.\(maxDecimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}
