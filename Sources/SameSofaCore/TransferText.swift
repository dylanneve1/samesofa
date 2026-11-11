import Foundation

/// The words for transfer progress: "126 MB of 2.1 GB · 5.2 MB/s".
public enum TransferText {
    public static func bytes(_ n: Int64) -> String {
        let v = Double(max(0, n))
        if v >= 1e9 { return String(format: "%.1f GB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.0f MB", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0f KB", v / 1e3) }
        return "\(Int64(v)) B"
    }

    public static func percent(_ fraction: Double) -> String {
        let p = max(0, min(1, fraction)) * 100
        return p < 10 ? String(format: "%.1f%%", p) : String(format: "%.0f%%", p)
    }

    /// `rate` in bytes per second (0 while unknown).
    public static func line(sending: Bool, received: Int64, total: Int64, rate: Double) -> String {
        var text = "\(sending ? "Sending the film" : "Receiving the film"): \(bytes(received)) of \(bytes(total))"
        if rate > 0 { text += String(format: " · %.1f MB/s", rate / 1e6) }
        if total > 0 { text += " · \(percent(Double(received) / Double(total)))" }
        return text
    }
}
