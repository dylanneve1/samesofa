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

/// A display that can be told to misbehave: refuse a mode, accept it and not follow, follow and
/// fall out of it again, answer with another resolution, go to sleep, disappear.
final class FakeDisplays: DisplayBackend {
    enum Behaviour { case obedient, refuses, ignores, wrongSize }
    var behaviour = Behaviour.obedient
    var online = true, asleep = false, mirrored = false
    /// How many restores are refused before one is accepted.
    var refuseRestores = 0
    let all: [DisplayModeInfo]
    var current: DisplayModeInfo
    var applied: [Double] = []

    init() {
        func mode(_ index: Int, _ hz: Double, w: Int = 3840, h: Int = 2160) -> DisplayModeInfo {
            DisplayModeInfo(index: index, width: w, height: h, pixelWidth: w, pixelHeight: h, refreshRate: hz, usableForDesktop: true)
        }
        all = [mode(0, 60), mode(1, 59.94), mode(2, 50), mode(3, 30), mode(4, 25), mode(5, 24), mode(6, 23.976), mode(7, 24, w: 1920, h: 1080)]
        current = all[0]
    }

    func isOnline(_ display: CGDirectDisplayID) -> Bool { online }
    func isAsleep(_ display: CGDirectDisplayID) -> Bool { asleep }
    func isMirrored(_ display: CGDirectDisplayID) -> Bool { mirrored }
    func modes(of display: CGDirectDisplayID) -> DisplayModeList? { DisplayModeList(current: current, all: all) }
    func currentMode(of display: CGDirectDisplayID) -> DisplayModeInfo? { current }

    func apply(_ mode: DisplayModeInfo, to display: CGDirectDisplayID) -> Bool {
        applied.append(mode.refreshRate)
        if mode.index == 0 {
            // Back to the original.
            if refuseRestores > 0 { refuseRestores -= 1; return false }
            current = all[0]
            return true
        }
        switch behaviour {
        case .obedient: current = mode; return true
        case .refuses: return false
        case .ignores: return true
        case .wrongSize: current = all[7]; return true
        }
    }
}

enum DisplayModeTest {
    /// A switch that fails or is refused, in every way one can: afterwards the display must be exactly as it
    /// was, nothing may count as switched, the reason must be on record, and the same switch must not be tried again.
    static func runFailureCases() -> Bool {
        var failed = false
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
            if !ok { failed = true }
        }
        func fresh(_ behaviour: FakeDisplays.Behaviour) -> (FakeDisplays, DisplayModeSwitcher) {
            let displays = FakeDisplays()
            displays.behaviour = behaviour
            return (displays, DisplayModeSwitcher(backend: displays, patience: 2))
        }
        let film = 24000.0 / 1001
        func asItWas(_ displays: FakeDisplays, _ switcher: DisplayModeSwitcher) -> Bool {
            displays.current == displays.all[0] && switcher.engaged == nil
        }

        var (displays, switcher) = fresh(.obedient)
        let mode = switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false)
        check("a display that follows is switched", mode?.refreshRate == 23.976 && displays.current.refreshRate == 23.976 && switcher.lastAttempt?.reverted == nil)
        check("and stays switched when looked at again", switcher.confirm() && switcher.engaged != nil)
        switcher.restore()
        check("and is put back", asItWas(displays, switcher))

        (displays, switcher) = fresh(.refuses)
        check("refused: nothing counts as switched", switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false) == nil && asItWas(displays, switcher))
        check("refused: the reason is on record", switcher.lastAttempt?.reverted?.contains("did not accept") == true && switcher.lastAttempt?.restored == true
                && switcher.lastAttempt?.to == 23.976, switcher.lastAttempt?.reverted ?? "-")
        let asked = switcher.applyCount
        _ = switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false)
        _ = switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false)
        check("refused: the same switch is not tried again", switcher.applyCount == asked && asItWas(displays, switcher), "asked \(switcher.applyCount) time(s)")
        switcher.forgetFailure()
        _ = switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false)
        check("refused: tried again only after full screen was left", switcher.applyCount == asked + 1 && asItWas(displays, switcher))

        (displays, switcher) = fresh(.ignores)
        check("accepted but not followed: undone", switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false) == nil && asItWas(displays, switcher)
                && switcher.lastAttempt?.reverted?.contains("did not switch") == true, switcher.lastAttempt?.reverted ?? "-")

        (displays, switcher) = fresh(.wrongSize)
        check("another resolution than asked for: undone, original size back", switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false) == nil
                && asItWas(displays, switcher) && displays.current.width == 3840, switcher.lastAttempt?.reverted ?? "-")

        (displays, switcher) = fresh(.obedient)
        _ = switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false)
        displays.current = displays.all[3] // the TV fell back to 30 Hz by itself
        check("fell out of the mode later: put back", !switcher.confirm() && asItWas(displays, switcher)
                && switcher.lastAttempt?.reverted?.contains("did not stay") == true, switcher.lastAttempt?.reverted ?? "-")
        let afterFall = switcher.applyCount
        _ = switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false)
        check("fell out of the mode later: not tried again for this film", switcher.applyCount == afterFall && asItWas(displays, switcher))

        (displays, switcher) = fresh(.obedient)
        _ = switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false)
        displays.asleep = true
        check("asleep after the switch: put back", !switcher.confirm() && asItWas(displays, switcher) && switcher.lastAttempt?.reverted != nil)

        (displays, switcher) = fresh(.obedient)
        _ = switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false)
        let before = displays.applied.count
        displays.online = false
        check("unplugged after the switch: forgotten, nothing sent to a display that is gone", !switcher.confirm() && switcher.engaged == nil
                && displays.applied.count == before && switcher.lastAttempt?.reverted != nil)

        (displays, switcher) = fresh(.obedient)
        _ = switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false)
        switcher.giveUp("The picture did not come back after the switch.")
        check("no picture after the switch: put back, with the reason", asItWas(displays, switcher)
                && switcher.lastAttempt?.reverted?.hasPrefix("The picture did not come back") == true, switcher.lastAttempt?.reverted ?? "-")

        (displays, switcher) = fresh(.obedient)
        _ = switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false)
        displays.refuseRestores = 2
        check("a restore that is refused twice is tried until it holds", switcher.restore() && asItWas(displays, switcher), "\(displays.applied.count) requests")

        (displays, switcher) = fresh(.obedient)
        displays.mirrored = true
        check("a mirrored display is never touched", switcher.engage(display: 1, filmFrameRate: film, variableRefresh: false) == nil && displays.applied.isEmpty)
        (displays, switcher) = fresh(.obedient)
        check("a variable-refresh display is never touched", switcher.engage(display: 1, filmFrameRate: film, variableRefresh: true) == nil && displays.applied.isEmpty)
        return !failed
    }

    static func describe(_ mode: DisplayModeInfo) -> String {
        "\(mode.width)x\(mode.height) pt, \(mode.pixelWidth)x\(mode.pixelHeight) px, \(DisplayModePlanner.formatNumber(mode.refreshRate, maxDecimals: 3)) Hz"
    }

    static func run(switchForReal: Bool) -> Never {
        _ = NSApplication.shared
        let casesOK = runFailureCases()
        guard let screen = NSScreen.main, let display = DisplayModeSwitcher.displayID(of: screen) else {
            print(casesOK ? "RESULT PASS: no display (only the simulated ones were tested)" : "RESULT FAIL: a simulated display was not handled")
            exit(casesOK ? 0 : 1)
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
        var failed = !casesOK
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
        print(failed ? "RESULT FAIL: \(casesOK ? "the display is not as it was" : "a simulated display was not handled")" : "RESULT PASS: the display is exactly as it was")
        exit(failed ? 1 : 0)
    }
}
