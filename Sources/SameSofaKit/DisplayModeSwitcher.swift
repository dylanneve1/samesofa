import AppKit
import CoreGraphics
import Foundation
import SameSofaCore

/// The current mode of a display and every mode it offers.
public struct DisplayModeList {
    public var current: DisplayModeInfo
    public var all: [DisplayModeInfo]
}

/// Switches a display to a refresh rate that suits the film and always
/// switches it back.
///
/// Main thread only. Resolution and scaling are never changed: only modes
/// with exactly the current size in points and in pixels are considered
/// (DisplayModePlanner). The change is made for this app only
/// (`CGConfigureOption.forAppOnly`), so the window server undoes it by
/// itself the moment the process is gone, however it dies. On top of that
/// the original mode is put back on `restore()`, at exit and on
/// SIGTERM/SIGINT/SIGHUP, and a switch that cannot be confirmed is undone
/// straight away.
public final class DisplayModeSwitcher {
    public static let shared = DisplayModeSwitcher()

    public struct Engagement {
        public var display: CGDirectDisplayID
        public var original: DisplayModeInfo
        public var active: DisplayModeInfo
        public var filmFrameRate: Double
    }

    /// The display that is currently switched, if any.
    public private(set) var engaged: Engagement?
    /// Why the last attempt changed nothing, in plain words (nil: it worked, or there was nothing to do).
    public private(set) var lastProblem: String?

    /// Refresh tolerance in Hz when comparing a mode with what the system reports.
    private let refreshTolerance = 0.05
    private var modeCache: [CGDirectDisplayID: [CGDisplayMode]] = [:]
    private var originalMode: CGDisplayMode?
    private var handlersInstalled = false
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []

    public init() {}

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

    /// Lists the modes of a display. The `index` of each entry is valid until the next call.
    public func modes(for display: CGDirectDisplayID) -> DisplayModeList? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard var cgModes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode],
              let currentCG = CGDisplayCopyDisplayMode(display) else { return nil }
        var currentIndex = cgModes.firstIndex { sameMode($0, currentCG) && $0.ioDisplayModeID == currentCG.ioDisplayModeID }
            ?? cgModes.firstIndex { sameMode($0, currentCG) }
        if currentIndex == nil {
            cgModes.append(currentCG)
            currentIndex = cgModes.count - 1
        }
        modeCache[display] = cgModes
        let infos = cgModes.enumerated().map { info($0.element, index: $0.offset) }
        return DisplayModeList(current: infos[currentIndex!], all: infos)
    }

    /// What `engage` would switch to, without changing anything. nil: the display is left alone.
    public func plan(display: CGDirectDisplayID, filmFrameRate: Double, variableRefresh: Bool) -> DisplayModeInfo? {
        guard CGDisplayIsOnline(display) != 0, !Self.isMirrored(display), let list = modes(for: display) else { return nil }
        // While switched, plan from the original mode.
        let current = engaged?.display == display ? engaged!.original : list.current
        return DisplayModePlanner.bestMode(filmFrameRate: filmFrameRate, current: current, available: list.all, variableRefresh: variableRefresh)
    }

    // MARK: Switching

    /// Switches the display to the best mode for the film. Returns the new
    /// mode, or nil when nothing was changed: no suitable mode, a mirrored
    /// display, or a switch that did not take and was undone.
    @discardableResult
    public func engage(display: CGDirectDisplayID, filmFrameRate: Double, variableRefresh: Bool) -> DisplayModeInfo? {
        if let current = engaged {
            if current.display == display, current.filmFrameRate == filmFrameRate, currentMatchesActive() { return current.active }
            restore()
        }
        lastProblem = nil
        guard CGDisplayIsOnline(display) != 0, CGDisplayIsAsleep(display) == 0 else { return nil }
        guard !Self.isMirrored(display) else {
            lastProblem = "Mirrored displays are left as they are."
            return nil
        }
        guard let list = modes(for: display), let cgModes = modeCache[display] else { return nil }
        guard let target = DisplayModePlanner.bestMode(filmFrameRate: filmFrameRate, current: list.current,
                                                       available: list.all, variableRefresh: variableRefresh),
              target.index >= 0, target.index < cgModes.count, target.sameGeometry(as: list.current),
              let currentCG = CGDisplayCopyDisplayMode(display) else { return nil }
        let targetCG = cgModes[target.index]
        // Belt and braces: the system's own numbers must agree that only the refresh rate differs.
        guard targetCG.width == currentCG.width, targetCG.height == currentCG.height,
              targetCG.pixelWidth == currentCG.pixelWidth, targetCG.pixelHeight == currentCG.pixelHeight else { return nil }
        installExitHandlers()
        originalMode = currentCG
        engaged = Engagement(display: display, original: list.current, active: target, filmFrameRate: filmFrameRate)
        guard apply(targetCG, to: display), verifyCurrent(display, matches: targetCG) else {
            restore()
            lastProblem = "The display did not accept the new refresh rate; it was left as it was."
            return nil
        }
        return target
    }

    /// Puts the display back in its original mode. Does nothing when nothing is switched.
    public func restore() {
        guard let current = engaged, let original = originalMode else {
            engaged = nil
            originalMode = nil
            return
        }
        engaged = nil
        originalMode = nil
        guard CGDisplayIsOnline(current.display) != 0 else { return }
        var ok = verifyCurrent(current.display, matches: original, attempts: 1)
        for _ in 0..<3 where !ok {
            _ = apply(original, to: current.display)
            ok = verifyCurrent(current.display, matches: original)
        }
        if !ok { NSLog("SameSofa: the display's original mode could not be confirmed; macOS restores it when SameSofa quits") }
    }

    /// Restores the display when the process quits or is told to stop, and
    /// forgets a display that was unplugged.
    public func installExitHandlers() {
        guard !handlersInstalled else { return }
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
            guard let self, let current = self.engaged, CGDisplayIsOnline(current.display) == 0 else { return }
            // The display is gone: nothing to put back.
            self.engaged = nil
            self.originalMode = nil
        })
    }

    // MARK: Helpers

    private func apply(_ mode: CGDisplayMode, to display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }

    /// Waits briefly for the system to report the expected mode.
    private func verifyCurrent(_ display: CGDirectDisplayID, matches expected: CGDisplayMode, attempts: Int = 10) -> Bool {
        for attempt in 0..<max(1, attempts) {
            if let now = CGDisplayCopyDisplayMode(display), sameMode(now, expected) { return true }
            if attempt < attempts - 1 { usleep(100_000) }
        }
        return false
    }

    private func currentMatchesActive() -> Bool {
        guard let current = engaged, let cgModes = modeCache[current.display], current.active.index < cgModes.count,
              let now = CGDisplayCopyDisplayMode(current.display) else { return false }
        return sameMode(now, cgModes[current.active.index])
    }

    /// Same size, same scaling and (within tolerance) the same refresh rate.
    private func sameMode(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
        a.width == b.width && a.height == b.height && a.pixelWidth == b.pixelWidth
            && a.pixelHeight == b.pixelHeight && abs(a.refreshRate - b.refreshRate) <= refreshTolerance
    }

    private func info(_ mode: CGDisplayMode, index: Int) -> DisplayModeInfo {
        DisplayModeInfo(index: index, width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                        refreshRate: mode.refreshRate, usableForDesktop: mode.isUsableForDesktopGUI())
    }
}
