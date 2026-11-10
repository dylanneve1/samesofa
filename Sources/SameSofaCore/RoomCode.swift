import Foundation

/// Six-character room codes, matching `server/rooms.js`.
public enum RoomCode {
    /// No 0/O or 1/I/L so codes survive being read aloud.
    public static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    public static let length = 6

    /// Turns whatever someone typed ("k7m-2pq", " K7M 2PQ ") into a code, or nil.
    public static func normalize(_ input: String) -> String? {
        let cleaned = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard cleaned.count == length, cleaned.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return cleaned
    }

    /// Characters accepted while typing (used to filter the input field).
    public static func sanitizeTyping(_ input: String) -> String {
        String(input.uppercased().filter { alphabet.contains($0) }.prefix(length))
    }

    /// "K7M2PQ" -> "K7M 2PQ" for display.
    public static func pretty(_ code: String) -> String {
        guard code.count == length else { return code }
        let mid = code.index(code.startIndex, offsetBy: length / 2)
        return code[..<mid] + " " + code[mid...]
    }
}
