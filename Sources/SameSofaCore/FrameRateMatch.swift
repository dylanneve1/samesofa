import Foundation

/// Showing a film's frames evenly: a 24 fps film on a display that refreshes
/// 60 times a second has to alternate between two and three refreshes per
/// frame (judder); at 48 or 120 Hz every frame gets the same time.
public enum FrameRateMatch {
    /// The refresh rate to ask a variable-refresh display for: the smallest
    /// whole multiple of the film's frame rate that is at least 40 Hz and
    /// that the display can do. nil when the frame rate is unknown.
    public static func preferredRefreshRate(filmFrameRate: Double, displayMaximum: Double) -> Double? {
        guard filmFrameRate >= 1, displayMaximum >= 1 else { return nil }
        var rate = filmFrameRate
        while rate < 40 { rate += filmFrameRate }
        // Allow for 119.88 on a "120 Hz" display and the like.
        if rate > displayMaximum * 1.005 { return rate - filmFrameRate >= filmFrameRate && rate - filmFrameRate <= displayMaximum * 1.005 ? rate - filmFrameRate : nil }
        return rate
    }

    /// On a display fixed at `refreshRate`: does every film frame get the
    /// same number of refreshes? (23.976 on 120 Hz counts: one repeated
    /// frame every eight seconds.)
    public static func isEvenCadence(filmFrameRate: Double, refreshRate: Double) -> Bool {
        guard filmFrameRate >= 1, refreshRate >= filmFrameRate * 0.99 else { return false }
        let ratio = refreshRate / filmFrameRate
        return abs(ratio - ratio.rounded()) < 0.01
    }
}
