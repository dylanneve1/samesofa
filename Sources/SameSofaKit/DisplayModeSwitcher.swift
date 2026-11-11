import AppKit
import CoreGraphics
import Foundation
import SameSofaCore

/// The current mode of a display and every mode it offers.
public struct DisplayModeList {
    public var current: DisplayModeInfo
    public var all: [DisplayModeInfo]

    public init(current: DisplayModeInfo, all: [DisplayModeInfo]) {
        self.current = current
        self.all = all
    }
}

/// What the switcher asks of the system. Tests put a display that refuses a
/// mode, ignores it or loses it again in its place; the app uses `SystemDisplays`.
/// A mode's `index` identifies it for as long as the backend lives.
public protocol DisplayBackend: AnyObject {
    func isOnline(_ display: CGDirectDisplayID) -> Bool
    func isAsleep(_ display: CGDirectDisplayID) -> Bool
    func isMirrored(_ display: CGDirectDisplayID) -> Bool
    func modes(of display: CGDirectDisplayID) -> DisplayModeList?
    func currentMode(of display: CGDirectDisplayID) -> DisplayModeInfo?
    /// Asks for the mode. true: the system accepted the request (which does not yet mean the display follows).
    func apply(_ mode: DisplayModeInfo, to display: CGDirectDisplayID) -> Bool
}

/// The real displays, through Core Graphics. Changes are made for this app
/// only (`CGConfigureOption.forAppOnly`), so the window server undoes them
/// by itself the moment the process is gone, however it dies.
public final class SystemDisplays: DisplayBackend {
    /// Every mode ever seen per display; an index into it never changes its meaning.
    private var table: [CGDirectDisplayID: [CGDisplayMode]] = [:]

    public init() {}

    public func isOnline(_ display: CGDirectDisplayID) -> Bool { CGDisplayIsOnline(display) != 0 }
    public func isAsleep(_ display: CGDirectDisplayID) -> Bool { CGDisplayIsAsleep(display) != 0 }
    public func isMirrored(_ display: CGDirectDisplayID) -> Bool { CGDisplayIsInMirrorSet(display) != 0 }

    private func same(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
        a.ioDisplayModeID == b.ioDisplayModeID && a.width == b.width && a.height == b.height && a.pixelWidth == b.pixelWidth
            && a.pixelHeight == b.pixelHeight && a.refreshRate == b.refreshRate && a.ioFlags == b.ioFlags
    }

    private func info(_ mode: CGDisplayMode, display: CGDirectDisplayID) -> DisplayModeInfo {
        var known = table[display] ?? []
        let index: Int
        if let found = known.firstIndex(where: { same($0, mode) }) {
            index = found
        } else {
            known.append(mode)
            table[display] = known
            index = known.count - 1
        }
        return DisplayModeInfo(index: index, width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                               refreshRate: mode.refreshRate, usableForDesktop: mode.isUsableForDesktopGUI())
    }

    public func modes(of display: CGDirectDisplayID) -> DisplayModeList? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode],
              let current = CGDisplayCopyDisplayMode(display) else { return nil }
        var infos = all.map { info($0, display: display) }
        let now = info(current, display: display)
        if !infos.contains(where: { $0.index == now.index }) { infos.append(now) }
        return DisplayModeList(current: now, all: infos)
    }

    public func currentMode(of display: CGDirectDisplayID) -> DisplayModeInfo? {
        CGDisplayCopyDisplayMode(display).map { info($0, display: display) }
    }

    public func apply(_ mode: DisplayModeInfo, to display: CGDirectDisplayID) -> Bool {
        guard let known = table[display], mode.index >= 0, mode.index < known.count else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, display, known[mode.index], nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }
}

/// Switches a display to a refresh rate that suits the film and always
/// switches it back.
///
/// Main thread only. Resolution and scaling are never changed: only modes
/// with exactly the current size in points and in pixels are considered
/// (DisplayModePlanner). The original mode is put back on `restore()`, at
/// exit and on SIGTERM/SIGINT/SIGHUP.
///
/// A switch is never taken on trust. It counts only once the display itself
/// reports the new mode with the same size and scaling; otherwise the
/// original mode is put back at once. A switch that did count is looked at
/// again a little later (`confirm`): a display that fell asleep, went away
/// or ended up in some other mode is put back too. Whatever goes wrong, the
/// attempt is remembered (`lastAttempt`) for the readout, and the same
/// switch is not tried again until `forgetFailure()` (leaving full screen,
/// another film), so a display that does not cooperate blanks at most once.
public final class DisplayModeSwitcher {
    public static let shared = DisplayModeSwitcher()

    public struct Engagement {
        public var display: CGDirectDisplayID
        public var original: DisplayModeInfo
        public var active: DisplayModeInfo
        public var filmFrameRate: Double
    }

    /// What became of the last attempt to switch a display.
    public struct Attempt: Equatable {
        public var display: CGDirectDisplayID
        public var filmFrameRate: Double
        /// Refresh rates in Hz: where the display was and where it was asked to go.
        public var from: Double
        public var to: Double
        /// nil: it worked. Otherwise why the display was put back, in plain words.
        public var reverted: String?
        /// The display is confirmed to be back in its original mode.
        public var restored = true
    }

    /// The display that is currently switched, if any.
    public private(set) var engaged: Engagement?
    /// Why the last attempt changed nothing, in plain words (nil: it worked, or there was nothing to do).
    public private(set) var lastProblem: String?
    public private(set) var lastAttempt: Attempt?
    /// How often the system was asked to change a mode (tests).
    public private(set) var applyCount = 0

    /// Refresh tolerance in Hz when comparing a mode with what the system reports.
    private let refreshTolerance = 0.05
    private let backend: DisplayBackend
    /// How long to wait for the display to report a mode, in tenths of a second.
    private let patience: Int
    private var handlersInstalled = false
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []
    /// A switch that failed: not tried again until forgotten.
    private var failed: (display: CGDirectDisplayID, filmFrameRate: Double)?

    public init(backend: DisplayBackend = SystemDisplays(), patience: Int = 10) {
        self.backend = backend
        self.patience = max(1, patience)
    }

    // MARK: Reading

    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// True for displays whose refresh rate follows the content by itself (ProMotion, adaptive sync).
    public static func isVariableRefresh(_ screen: NSScreen) -> Bool {
        screen.maximumRefreshInterval > screen.minimumRefreshInterval * 1.05
    }

    public static func isMirrored(_ display: CGDirectDisplayID) -> Bool { CGDisplayIsInMirrorSet(display) != 0 }

    /// The refresh rate the display runs at now (0 when the system does not say).
    public static func currentRefreshRate(of display: CGDirectDisplayID) -> Double {
        CGDisplayCopyDisplayMode(display)?.refreshRate ?? 0
    }

    /// Lists the modes of a display.
    public func modes(for display: CGDirectDisplayID) -> DisplayModeList? { backend.modes(of: display) }

    /// What `engage` would switch to, without changing anything. nil: the display is left alone.
    public func plan(display: CGDirectDisplayID, filmFrameRate: Double, variableRefresh: Bool) -> DisplayModeInfo? {
        guard backend.isOnline(display), !backend.isMirrored(display), let list = backend.modes(of: display) else { return nil }
        // While switched, plan from the original mode.
        let current = engaged?.display == display ? engaged!.original : list.current
        return DisplayModePlanner.bestMode(filmFrameRate: filmFrameRate, current: current, available: list.all, variableRefresh: variableRefresh)
    }

    // MARK: Switching

    /// Switches the display to the best mode for the film. Returns the new
    /// mode, or nil when nothing was changed: no suitable mode, a mirrored
    /// display, a switch that failed before, or one that did not take and was undone.
    @discardableResult
    public func engage(display: CGDirectDisplayID, filmFrameRate: Double, variableRefresh: Bool) -> DisplayModeInfo? {
        if let current = engaged {
            if current.display == display, current.filmFrameRate == filmFrameRate, currentMatches(current.active, on: display) { return current.active }
            restore()
        }
        // The same switch failed a moment ago: once is enough.
        if let failed, failed.display == display, failed.filmFrameRate == filmFrameRate { return nil }
        lastProblem = nil
        guard backend.isOnline(display), !backend.isAsleep(display) else { return nil }
        guard !backend.isMirrored(display) else {
            lastProblem = "Mirrored displays are left as they are."
            return nil
        }
        guard let list = backend.modes(of: display) else { return nil }
        guard let target = DisplayModePlanner.bestMode(filmFrameRate: filmFrameRate, current: list.current,
                                                       available: list.all, variableRefresh: variableRefresh),
              target.sameGeometry(as: list.current) else { return nil }
        installExitHandlers()
        engaged = Engagement(display: display, original: list.current, active: target, filmFrameRate: filmFrameRate)
        lastAttempt = Attempt(display: display, filmFrameRate: filmFrameRate, from: list.current.refreshRate, to: target.refreshRate, reverted: nil)
        applyCount += 1
        guard backend.apply(target, to: display) else {
            // Nothing should have changed; make sure of it all the same.
            revert("The display did not accept the new refresh rate.")
            return nil
        }
        guard verify(display, is: target) else {
            revert("The display did not switch to the new refresh rate.")
            return nil
        }
        return target
    }

    /// A while after a switch: is the display still on, awake and in the
    /// mode it was switched to? If not, it is put back. Returns false when
    /// it had to be (or when nothing is switched).
    @discardableResult
    public func confirm() -> Bool {
        guard let current = engaged else { return false }
        guard backend.isOnline(current.display) else {
            // The display is gone: nothing to put back.
            engaged = nil
            note("The display was disconnected.", restored: true)
            return false
        }
        if backend.isAsleep(current.display) {
            revert("The display went to sleep after the switch.")
            return false
        }
        guard currentMatches(current.active, on: current.display) else {
            revert("The display did not stay at the new refresh rate.")
            return false
        }
        return true
    }

    /// The caller saw that the film is not being shown after a switch (no
    /// picture, the window on another display): back to the original mode.
    public func giveUp(_ reason: String) {
        guard engaged != nil else { return }
        revert(reason)
    }

    /// A failed switch may be tried again (full screen was left, another film).
    public func forgetFailure() {
        failed = nil
    }

    /// The evening is over: nothing to report any more.
    public func forgetAttempt() {
        failed = nil
        lastAttempt = nil
        lastProblem = nil
    }

    /// Screenshots only: shows the note of a switch that was undone.
    public func pretendRevertedForTesting(display: CGDirectDisplayID, filmFrameRate: Double, from: Double, to: Double) {
        lastAttempt = Attempt(display: display, filmFrameRate: filmFrameRate, from: from, to: to, reverted: "The display did not switch to the new refresh rate.")
    }

    private func note(_ reason: String, restored: Bool) {
        lastProblem = reason
        if var attempt = lastAttempt {
            attempt.reverted = reason
            attempt.restored = restored
            lastAttempt = attempt
            failed = (attempt.display, attempt.filmFrameRate)
        }
    }

    private func revert(_ reason: String) {
        let ok = restore()
        note(reason + (ok ? " It was put back as it was." : " macOS puts it back when SameSofa quits."), restored: ok)
    }

    /// Puts the display back in its original mode. Does nothing when nothing
    /// is switched. Returns true when the display is (confirmed to be) as it was.
    @discardableResult
    public func restore() -> Bool {
        guard let current = engaged else { return true }
        engaged = nil
        guard backend.isOnline(current.display) else { return true }
        var ok = verify(current.display, is: current.original, attempts: 1)
        for _ in 0..<3 where !ok {
            applyCount += 1
            _ = backend.apply(current.original, to: current.display)
            ok = verify(current.display, is: current.original)
        }
        if !ok { NSLog("SameSofa: the display's original mode could not be confirmed; macOS restores it when SameSofa quits") }
        return ok
    }

    /// Restores the display when the process quits or is told to stop, and
    /// forgets a display that was unplugged.
    public func installExitHandlers() {
        guard !handlersInstalled, self === DisplayModeSwitcher.shared else { return }
        handlersInstalled = true
        atexit { DisplayModeSwitcher.shared.restore() }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                // Restore on the main thread; if that is stuck, leave anyway
                // (the window server restores an app-only mode when we are gone).
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    DisplayModeSwitcher.shared.restore()
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 2)
                _exit(128 + sig)
            }
            source.resume()
            signalSources.append(source)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restore()
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let current = self.engaged, !self.backend.isOnline(current.display) else { return }
            // The display is gone: nothing to put back.
            self.engaged = nil
        })
    }

    // MARK: Helpers

    /// Waits briefly for the system to report the expected mode.
    private func verify(_ display: CGDirectDisplayID, is expected: DisplayModeInfo, attempts: Int? = nil) -> Bool {
        let attempts = max(1, attempts ?? patience)
        for attempt in 0..<attempts {
            if currentMatches(expected, on: display) { return true }
            if attempt < attempts - 1 { usleep(100_000) }
        }
        return false
    }

    /// Same size, same scaling and (within tolerance) the same refresh rate as the display reports now.
    private func currentMatches(_ expected: DisplayModeInfo, on display: CGDirectDisplayID) -> Bool {
        guard let now = backend.currentMode(of: display) else { return false }
        return now.sameGeometry(as: expected) && abs(now.refreshRate - expected.refreshRate) <= refreshTolerance
    }
}
