// Developer helper: screenshot only SameSofa's windows (no desktop, no other apps).
// Usage: swift scripts/dev/window-shot.swift <pid> <out-prefix>
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let prefix = CommandLine.arguments[2]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var n = 0
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    guard let id = w[kCGWindowNumber as String] as? Int else { continue }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", String(id), "\(prefix)\(n == 0 ? "" : "-\(n)").png"]
    try p.run(); p.waitUntilExit()
    print("captured window \(id) -> \(prefix)\(n == 0 ? "" : "-\(n)").png")
    n += 1
}
if n == 0 { print("no windows for pid \(pid)") }
