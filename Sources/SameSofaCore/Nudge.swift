import Foundation

/// A guest's speed correction in progress.
///
/// A small gap to the host is closed by playing slightly faster or slower:
/// one speed for the whole correction, chosen at its start. The state lives
/// here, apart from the player: whenever something else sets the player's
/// speed (a seek, a scheduled start, a pause) the correction is over and
/// `reset()` has to be called, so that the next one starts cleanly.
public struct NudgeState: Equatable, Sendable {
    /// The speed set for the correction under way (nil: none).
    public private(set) var rate: Double?

    public init() {}

    public var isNudging: Bool { rate != nil }

    public mutating func reset() { rate = nil }

    /// `wanted`: the speed the sync engine asks for (`PlayerCorrection.adjustRate`).
    /// Returns the speed to set on the player now, or nil to leave it as it is.
    public mutating func adjust(to wanted: Double) -> Double? {
        if let rate, (rate > 1) == (wanted > 1) { return nil }
        rate = wanted
        return wanted
    }
}
