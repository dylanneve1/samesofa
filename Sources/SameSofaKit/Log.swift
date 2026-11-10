import Foundation

/// Debug logging, enabled with the environment variable SAMESOFA_DEBUG=1.
/// Never logs message contents, codes or addresses.
enum Log {
    static let enabled = ProcessInfo.processInfo.environment["SAMESOFA_DEBUG"] == "1"
    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("[samesofa] " + message() + "\n").utf8))
    }
}
