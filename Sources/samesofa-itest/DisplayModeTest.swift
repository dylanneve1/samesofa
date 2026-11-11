import AppKit
import CoreGraphics
import Foundation
import SameSofaCore
import SameSofaKit

// The display's modes and what the frame-rate matching would do with them:
//
//   samesofa-itest --display-mode-test 1 [--switch 1]
//
// Without --switch nothing is changed: the modes are listed and the plan for
// the usual film rates is printed. With --switch the main display is really
// switched for a 23.976 fps film (if it offers a mode for it at the same
// resolution and scaling), held for two seconds and restored; then the same
// again with the restore left to a second switch for a 25 fps film. The
// display's mode is printed before and after and must be identical.

enum DisplayModeTest {
    static func describe(_ mode: DisplayModeInfo) -> String {
        "\(mode.width)x\(mode.height) pt, \(mode.pixelWidth)x\(mode.pixelHeight) px, \(DisplayModePlanner.formatNumber(mode.refreshRate, maxDecimals: 3)) Hz"
    }

    static func run(switchForReal: Bool) -> Never {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, let display = DisplayModeSwitcher.displayID(of: screen) else {
            print("RESULT PASS: no display (nothing to test)")
            exit(0)
        }
        let switcher = DisplayModeSwitcher.shared
        guard let list = switcher.modes(for: display) else { print("RESULT FAIL: the display's modes could not be read"); exit(1) }
        let variable = DisplayModeSwitcher.isVariableRefresh(screen), mirrored = DisplayModeSwitcher.isMirrored(display)
        let before = describe(list.current)
        print("before: \(before)")
        let sameGeometry = list.all.filter { $0.sameGeometry(as: list.current) && $0.usableForDesktop }
        let rates = Set(sameGeometry.map { DisplayModePlanner.formatNumber($0.refreshRate, maxDecimals: 2) }).sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }
        print("modes: \(list.all.count) in all; at this resolution and scaling: \(rates.joined(separator: ", ")) Hz; variable refresh: \(variable ? "yes" : "no"); mirrored: \(mirrored ? "yes" : "no")")
        for film in [24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 50, 60000.0 / 1001, 60] {
            let plan = switcher.plan(display: display, filmFrameRate: film, variableRefresh: variable)
            let now = DisplayModePlanner.describe(filmFrameRate: film, refreshRate: list.current.refreshRate, variableRefresh: variable, switched: false)
            print("  \(now)  ->  " + (plan.map { "switch to \(DisplayModePlanner.formatNumber($0.refreshRate, maxDecimals: 3)) Hz in full screen" } ?? "leave the display alone"))
        }
        var failed = false
        if switchForReal {
            for film in [24000.0 / 1001, 25.0] {
                if let mode = switcher.engage(display: display, filmFrameRate: film, variableRefresh: variable) {
                    let during = switcher.modes(for: display).map { describe($0.current) } ?? "?"
                    print("switched for \(DisplayModePlanner.formatNumber(film, maxDecimals: 3)) fps: \(during)")
                    if !mode.sameGeometry(as: list.current) { failed = true; print("FAIL the mode has another resolution or scaling") }
                    RunLoop.main.run(until: Date().addingTimeInterval(2))
                } else {
                    print("no switch for \(DisplayModePlanner.formatNumber(film, maxDecimals: 3)) fps: \(switcher.lastProblem ?? "no suitable mode, the display is left alone")")
                }
            }
            switcher.restore()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        let after = switcher.modes(for: display).map { describe($0.current) } ?? "?"
        print("after:  \(after)")
        if after != before || switcher.engaged != nil { failed = true }
        print(failed ? "RESULT FAIL: the display is not as it was" : "RESULT PASS: the display is exactly as it was")
        exit(failed ? 1 : 0)
    }
}
