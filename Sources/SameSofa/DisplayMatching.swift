import AppKit
import Combine
import SameSofaCore
import SameSofaKit

/// Settings ▸ Video ▸ "Match display to film in full screen".
///
/// A display with a fixed refresh rate shows a 24 fps film unevenly at 60 Hz.
/// Many TVs and monitors offer other rates at the same resolution. While
/// SameSofa is in full screen with a film loaded, the display the window is
/// on is switched to the rate that suits the film, and it is switched back
/// when full screen ends, the film changes or goes, SameSofa is no longer the
/// app in front, or it quits. Displays that follow the content by
/// themselves (ProMotion, adaptive sync) and mirrored displays are never
/// touched. All the deciding is in DisplayModePlanner, all the switching in
/// DisplayModeSwitcher.
final class DisplayMatcher: ObservableObject {
    static let shared = DisplayMatcher()

    private let switcher = DisplayModeSwitcher.shared
    private var cancellables: Set<AnyCancellable> = []
    private var filmCancellable: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var frameRate = 0.0
    private var enabled = true
    /// Between "will exit" and "did exit" full screen the window still says it is in full screen.
    private var leavingFullScreen = false
    private var active = true
    private var started = false

    func start(model: AppModel) {
        guard !started else { return }
        started = true
        // Screenshot and test runs never change the display.
        guard !LaunchOptions.shared.isScripted || LaunchOptions.shared.allowDisplayMatch else { return }
        switcher.installExitHandlers()
        model.settings.$displayMatch.sink { [weak self] value in
            self?.enabled = value != "off"
            DispatchQueue.main.async { self?.update() }
        }.store(in: &cancellables)
        model.$party.sink { [weak self] party in
            guard let self else { return }
            self.filmCancellable = party?.playback.$frameRate.sink { [weak self] rate in
                self?.frameRate = rate
                DispatchQueue.main.async { self?.update() }
            }
            if party == nil {
                self.frameRate = 0
                DispatchQueue.main.async { self.update() }
            }
        }.store(in: &cancellables)

        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ body: @escaping (DisplayMatcher) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if let self { body(self) }
            })
        }
        observe(NSWindow.didEnterFullScreenNotification) { $0.leavingFullScreen = false; $0.update() }
        observe(NSWindow.willExitFullScreenNotification) { $0.leavingFullScreen = true; $0.update() }
        observe(NSWindow.didExitFullScreenNotification) { $0.leavingFullScreen = false; $0.update() }
        observe(NSWindow.didChangeScreenNotification) { $0.update() }
        observe(NSWindow.willCloseNotification) { matcher in DispatchQueue.main.async { matcher.update() } }
        observe(NSApplication.didChangeScreenParametersNotification) { $0.update() }
        observe(NSApplication.didBecomeActiveNotification) { $0.active = true; $0.update() }
        observe(NSApplication.didResignActiveNotification) { matcher in
            matcher.active = false
            // A glance at another app does not blank the screen twice; staying away does restore it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if !matcher.active { matcher.update() } }
        }
        observe(NSApplication.willTerminateNotification) { $0.frameRate = 0; $0.switcher.restore() }
    }

    /// The film window in full screen, if it is.
    private var fullScreenWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.styleMask.contains(.fullScreen) }
    }

    /// Engages or restores, whichever the current state calls for.
    private func update() {
        guard enabled, active, !leavingFullScreen, frameRate >= 1, let screen = fullScreenWindow?.screen,
              let display = DisplayModeSwitcher.displayID(of: screen) else {
            if switcher.engaged != nil {
                switcher.restore()
                objectWillChange.send()
            }
            return
        }
        let before = switcher.engaged?.active
        let now = switcher.engage(display: display, filmFrameRate: frameRate, variableRefresh: DisplayModeSwitcher.isVariableRefresh(screen))
        if before != now { objectWillChange.send() }
    }

    /// The ⓘ readout's "Display" row: the display, and the cadence in effect with what could be done about it.
    func readout(filmFrameRate: Double, settingOn: Bool) -> (title: String, detail: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let screen = window.screen ?? NSScreen.main else {
            return ("Unknown", "")
        }
        let display = DisplayModeSwitcher.displayID(of: screen)
        let variable = DisplayModeSwitcher.isVariableRefresh(screen)
        var refresh = display.map(DisplayModeSwitcher.currentRefreshRate(of:)) ?? 0
        if refresh < 1 { refresh = Double(screen.maximumFramesPerSecond) }
        let hz = DisplayModePlanner.formatNumber(refresh, maxDecimals: 2)
        let title = "\(screen.localizedName.isEmpty ? "This display" : screen.localizedName) · \(hz) Hz" + (variable ? ", variable" : "")
        guard filmFrameRate >= 1 else { return (title, "") }
        let switched = display != nil && switcher.engaged?.display == display
        var detail = DisplayModePlanner.describe(filmFrameRate: filmFrameRate, refreshRate: refresh, variableRefresh: variable, switched: switched)
        guard !variable, !switched, !DisplayModePlanner.isEven(filmFrameRate: filmFrameRate, refreshRate: refresh), let display else { return (title, detail) }
        // Judder: say what would help.
        if DisplayModeSwitcher.isMirrored(display) {
            detail += " Mirrored displays are left as they are; turn mirroring off to let SameSofa match the display."
        } else if let better = switcher.plan(display: display, filmFrameRate: filmFrameRate, variableRefresh: false) {
            let target = DisplayModePlanner.formatNumber(better.refreshRate, maxDecimals: 2)
            if !settingOn {
                detail += " Settings ▸ Video ▸ Match display to film in full screen lets SameSofa switch this display to \(target) Hz."
            } else if let problem = switcher.lastProblem, window.styleMask.contains(.fullScreen) {
                detail += " \(problem)"
            } else {
                detail += " In full screen SameSofa switches this display to \(target) Hz."
            }
        } else {
            detail += " This display offers no refresh rate at this resolution that suits the film."
        }
        return (title, detail)
    }
}
