import AppKit
import AVFoundation
import Combine
import SameSofaCore
import SameSofaKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings the user (well, the technical one of the two) can change.
final class AppSettings: ObservableObject {
    static let placeholderServer = "wss://CHANGE-ME.example"

    /// Baked in at build time by scripts/build.sh (SAMESOFA_SERVER_URL), else the placeholder.
    static var builtInServer: String {
        (Bundle.main.object(forInfoDictionaryKey: "SameSofaDefaultServerURL") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? placeholderServer
    }

    /// A TURN relay baked in at build time by scripts/build.sh (SAMESOFA_TURN_URL,
    /// SAMESOFA_TURN_USERNAME, SAMESOFA_TURN_CREDENTIAL), if any. Used while the
    /// TURN server field in Settings is empty; never shown there.
    static var builtInRelay: (url: String, username: String, credential: String)? {
        func value(_ key: String) -> String { (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "" }
        let url = value("SameSofaDefaultTurnURL")
        return url.isEmpty ? nil : (url, value("SameSofaDefaultTurnUsername"), value("SameSofaDefaultTurnCredential"))
    }

    private let defaults = UserDefaults.standard
    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    @Published var stunURLs: String { didSet { defaults.set(stunURLs, forKey: "stunURLs") } }
    @Published var turnURL: String { didSet { defaults.set(turnURL, forKey: "turnURL") } }
    @Published var turnUsername: String { didSet { defaults.set(turnUsername, forKey: "turnUsername") } }
    @Published var turnCredential: String { didSet { defaults.set(turnCredential, forKey: "turnCredential") } }
    /// "automatic", "headphones" (on) or "speakers" (off): see EchoSetting.
    @Published var soundOutput: String { didSet { defaults.set(soundOutput, forKey: "soundOutput") } }
    /// Leave spatial audio (Dolby Atmos, AirPods) to the system instead of a plain downmix.
    @Published var systemSpatialAudio: Bool { didSet { defaults.set(systemSpatialAudio, forKey: "systemSpatialAudio") } }
    /// Ask variable-refresh displays to follow the film's frame rate.
    @Published var matchFrameRate: Bool { didSet { defaults.set(matchFrameRate, forKey: "matchFrameRate") } }
    /// "automatic" or "off": in full screen, switch a fixed-rate display to a refresh rate that suits the film.
    @Published var displayMatch: String { didSet { defaults.set(displayMatch, forKey: "displayMatch") } }

    /// How much disk space films kept for resuming may take, in GB (0: keep nothing).
    @Published var keepFilmsGB: Double { didSet { defaults.set(keepFilmsGB, forKey: "keepFilmsGB") } }

    var echoSetting: EchoSetting { EchoSetting(rawValue: soundOutput) ?? .automatic }

    init() {
        serverURL = defaults.string(forKey: "serverURL") ?? AppSettings.builtInServer
        stunURLs = defaults.string(forKey: "stunURLs") ?? IceSettings.defaultSTUN.joined(separator: ", ")
        turnURL = defaults.string(forKey: "turnURL") ?? ""
        turnUsername = defaults.string(forKey: "turnUsername") ?? ""
        turnCredential = defaults.string(forKey: "turnCredential") ?? ""
        soundOutput = defaults.string(forKey: "soundOutput") ?? EchoSetting.automatic.rawValue
        systemSpatialAudio = defaults.bool(forKey: "systemSpatialAudio")
        matchFrameRate = defaults.object(forKey: "matchFrameRate") as? Bool ?? true
        displayMatch = defaults.string(forKey: "displayMatch") ?? "automatic"
        keepFilmsGB = defaults.object(forKey: "keepFilmsGB") as? Double ?? Double(FilmCachePolicy.defaultCapacity >> 30)
        // A command-line override is handy for testing two copies on one Mac.
        if let override = LaunchOptions.shared.server { serverURL = override }
    }

    var isConfigured: Bool {
        guard let url = URL(string: serverURL), let scheme = url.scheme, ["ws", "wss"].contains(scheme) else { return false }
        return !serverURL.contains("CHANGE-ME")
    }

    /// The user's own relay if the TURN server field is filled in, else the built-in one, else none.
    var ice: IceSettings {
        let stun = stunURLs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if turnURL.trimmingCharacters(in: .whitespaces).isEmpty, let relay = Self.builtInRelay {
            return IceSettings(stunURLs: stun, turnURL: relay.url, turnUsername: relay.username, turnCredential: relay.credential)
        }
        return IceSettings(stunURLs: stun, turnURL: turnURL, turnUsername: turnUsername, turnCredential: turnCredential)
    }
}

/// Command-line switches, used for demos, screenshots and testing two copies
/// on one Mac. Normal users never see these.
struct LaunchOptions {
    static let shared = LaunchOptions()
    var server: String?
    var hostFilm: URL?
    var joinCode: String?
    var codeFile: URL?
    /// Synthetic camera and microphone, no audio hardware.
    var synthetic = false
    var label = "Me"
    var autoPlay = false
    /// Screenshots only: the host starts the film before anyone has joined.
    var playAlone = false
    /// Turn subtitles on as soon as the film has them.
    var subtitles = false
    /// Screenshots only: open on a given screen with a partly typed code.
    var screen: String?
    /// Screenshots only: open "quality", "acknowledgements", "about", "shortcuts" or "settings" without a click.
    var show: String?
    var prefill: String?
    /// Self-test: deliver these key presses to the join screen through the
    /// window (not the system), and record what code the app tried to join.
    var typeTest: String?
    var typeTestOutput: URL?
    /// Screenshots only: with `--show settings`, press "Test connection" by itself; the result is also written to this file.
    var testConnectionOutput: String?
    /// Scripted runs never change the display's refresh rate unless this is given.
    var allowDisplayMatch = false
    /// Host: open a room without a film.
    var room = false
    /// Things to do by themselves once the two are together (or, with `--script-alone`, once the room is
    /// open), for tests and screenshots: "8:film=/path/a.mp4;20:close;25:film=/path/b.mkv;40:drop;50:leave".
    /// Seconds count from that moment. Actions: film=<path>, close, play, pause, seek=<seconds>, drop,
    /// camera=on|off, mic=on|off, leave.
    var script: [(after: Double, action: String, argument: String)] = []
    var scriptAlone = false

    init() {
        var args = ArraySlice(CommandLine.arguments.dropFirst())
        while let key = args.popFirst() {
            switch key {
            case "--server": server = args.popFirst()
            case "--host": hostFilm = args.popFirst().map { URL(fileURLWithPath: $0) }
            case "--join": joinCode = args.popFirst()
            case "--code-file": codeFile = args.popFirst().map { URL(fileURLWithPath: $0) }
            case "--synthetic": synthetic = true
            case "--label": label = args.popFirst() ?? label
            case "--autoplay": autoPlay = true
            case "--play-alone": playAlone = true
            case "--subtitles": subtitles = true
            case "--screen": screen = args.popFirst()
            case "--show": show = args.popFirst()
            case "--prefill": prefill = args.popFirst()
            case "--type-test": typeTest = args.popFirst()
            case "--type-test-output": typeTestOutput = args.popFirst().map { URL(fileURLWithPath: $0) }
            case "--allow-display-match": allowDisplayMatch = true
            case "--test-connection": testConnectionOutput = args.popFirst()
            case "--room": room = true
            case "--script-alone": scriptAlone = true
            case "--script":
                for step in (args.popFirst() ?? "").split(separator: ";") {
                    let parts = step.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, let after = Double(parts[0]) else { continue }
                    let action = parts[1].split(separator: "=", maxSplits: 1)
                    script.append((after, String(action[0]), action.count > 1 ? String(action[1]) : ""))
                }
            default: break
            }
        }
    }
}

final class AppModel: ObservableObject {
    enum Screen: Equatable {
        case welcome
        case join
        case party
    }

    @Published var screen: Screen = .welcome
    @Published var party: Party?
    @Published var notice: String?
    let settings = AppSettings()
    private var cancellables: Set<AnyCancellable> = []
    private let options = LaunchOptions.shared

    /// The host's Mac is checking the film it was given (ffprobe), before the room opens.
    @Published var inspecting = false
    private var sweepTimer: Timer?

    private func observeSettings() {
        // The headphones setting applies straight away, also in the middle of a film.
        settings.$soundOutput.sink { [weak self] value in
            self?.party?.hub.echoSetting = EchoSetting(rawValue: value) ?? .automatic
        }.store(in: &cancellables)
        // So does the limit for kept films.
        settings.$keepFilmsGB.sink { value in
            FilmCache.shared.capacity = Int64(max(0, value) * Double(1 << 30))
            DispatchQueue.global(qos: .utility).async { FilmCache.shared.sweep() }
        }.store(in: &cancellables)
    }

    init() {
        // Converted films from a session that didn't end cleanly.
        FilmPreparer.removeLeftovers()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // Stops a running conversion and deletes the converted film.
            self?.party?.leave()
            FilmPreparer.removeLeftovers()
        }
        observeSettings()
        // Films kept for resuming: remove what is too old now and every hour.
        DispatchQueue.global(qos: .utility).async { FilmCache.shared.sweep() }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { FilmCache.shared.sweep() }
        }
        DisplayMatcher.shared.start(model: self)
        DispatchQueue.main.async { self.runLaunchOptions() }
    }

    /// Containers the host can pick. MP4/MOV are shared as they are; the rest
    /// are converted to MP4 by the FFmpeg helper first.
    static let filmExtensions = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "divx", "xvid", "ts", "m2ts", "mts",
                                 "flv", "wmv", "asf", "mpg", "mpeg", "vob", "ogv", "ogm", "3gp", "3g2", "rm", "rmvb"]

    private func runLaunchOptions() {
        if let film = options.hostFilm { startHosting(film: film) } else if options.room { startRoom() }
        if let code = options.joinCode { join(code: code) }
        if options.screen == "join" { screen = .join }
        if let text = options.typeTest { runTypeTest(text) }
    }

    private func partySettings() -> PartySettings? {
        guard settings.isConfigured, let url = URL(string: settings.serverURL) else {
            notice = "This copy of SameSofa doesn't know its server yet. Open SameSofa ▸ Settings… and enter the server address."
            return nil
        }
        let synthetic = options.synthetic
        var party = PartySettings(serverURL: url, ice: settings.ice,
                             audioMode: synthetic ? .synthetic : .live, echo: settings.echoSetting,
                             camera: synthetic ? .synthetic(label: options.label, hue: options.joinCode == nil ? 0.62 : 0.05) : .camera)
        party.systemSpatialAudio = settings.systemSpatialAudio
        return party
    }

    // MARK: Choosing a film

    /// A film can be chosen now: on the first screen (it opens a room with
    /// it), or by the host of a room (it replaces the film; the call goes on).
    var canChooseFilm: Bool {
        switch screen {
        case .welcome: return !inspecting
        case .join: return false
        case .party: return party?.canChangeFilm ?? false
        }
    }

    var canCloseFilm: Bool {
        guard screen == .party, let party else { return false }
        return party.canChangeFilm && party.hasFilmActivity
    }

    /// The button, File ▸ Open… and ⌘O: shows the file panel, then `openFilm`.
    func chooseFilm() {
        guard canChooseFilm else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a film to watch together"
        panel.prompt = "Watch this"
        let extra = Self.filmExtensions.compactMap { UTType(filenameExtension: $0, conformingTo: .movie) }
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audiovisualContent] + extra
        panel.allowsMultipleSelection = false
        // Not modal: the call and the film go on while the panel is open.
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openFilm(url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    /// A film was picked or dropped on the window.
    func openFilm(_ url: URL) {
        guard canChooseFilm else { return }
        if screen == .party, let party {
            // In a room: the film changes, nothing else does.
            party.changeFilm(to: url)
        } else {
            startHosting(film: url)
        }
    }

    func closeFilm() {
        guard canCloseFilm else { return }
        party?.closeFilm()
    }

    /// "Start a room": no film; the two see and hear each other, and a film can be chosen later.
    func startRoom() {
        guard let ps = partySettings() else { return }
        notice = nil
        Task { @MainActor in
            await Self.requestPermissions(synthetic: options.synthetic)
            let party = Party(role: .host, settings: ps)
            party.openRoom()
            self.attach(party)
        }
    }

    func startHosting(film: URL) {
        guard let ps = partySettings() else { return }
        notice = nil
        Task { @MainActor in
            await Self.requestPermissions(synthetic: options.synthetic)
            // Check the film before opening a room: shared as it is, converted
            // first (MKV, AVI, ...), or not usable at all.
            self.inspecting = true
            let check: FilmCheck
            do {
                check = try await FilmPreparer.inspect(film)
            } catch {
                self.inspecting = false
                self.notice = error.localizedDescription
                return
            }
            self.inspecting = false
            let party = Party(role: .host, settings: ps)
            do {
                try party.host(film: film, check: check)
            } catch {
                self.notice = "Couldn't open that file (\(error.localizedDescription)). Check that it is still where it was, or pick another film."
                return
            }
            self.attach(party)
        }
    }

    func join(code: String) {
        if let out = options.typeTestOutput { try? "join:\(code)".write(to: out, atomically: true, encoding: .utf8) }
        guard let ps = partySettings() else { return }
        notice = nil
        Task { @MainActor in
            await Self.requestPermissions(synthetic: options.synthetic)
            let party = Party(role: .guest, settings: ps)
            party.join(code: code)
            self.attach(party)
        }
    }

    private func attach(_ party: Party) {
        self.party = party
        screen = .party
        var scriptStarted = false
        party.$phase.sink { [weak self] phase in
            guard let self else { return }
            if case .waitingForPartner(let code) = phase, let file = self.options.codeFile {
                try? code.write(to: file, atomically: true, encoding: .utf8)
            }
            if case .waitingForPartner = phase, self.options.playAlone, party.role == .host {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if !party.playback.intendsToPlay { party.playback.play() } }
            }
            if phase == .together, self.options.autoPlay, party.role == .host {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { party.playback.play() }
            }
            var begin = phase == .together
            if case .waitingForPartner = phase, self.options.scriptAlone { begin = true }
            if begin, !scriptStarted {
                scriptStarted = true
                self.runScript(on: party)
            }
        }.store(in: &cancellables)
        if options.subtitles {
            party.playback.$hasSubtitles.filter { $0 }.first().receive(on: DispatchQueue.main)
                .sink { [weak party] _ in party?.playback.setSubtitles(true) }.store(in: &cancellables)
        }
        // Forward changes so views observing the model refresh.
        party.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    /// Tests and screenshots: the steps of `--script`, each at its time.
    private func runScript(on party: Party) {
        for step in options.script {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.after) { [weak self, weak party] in
                guard let self, let party, party === self.party else { return }
                switch step.action {
                // Straight to the party, so that a refusal (an older partner) is on record in its log.
                case "film": party.changeFilm(to: URL(fileURLWithPath: step.argument))
                case "close": party.closeFilm()
                case "play": party.playback.play()
                case "pause": party.playback.pause()
                case "seek": party.playback.seek(to: Double(step.argument) ?? 0)
                case "drop": party.dropConnectionForTesting()
                case "camera": party.cameraOn = step.argument != "off"
                case "mic": party.micOn = step.argument != "off"
                case "leave": self.leaveParty()
                default: break
                }
            }
        }
    }

    func leaveParty() {
        party?.leave()
        party = nil
        cancellables.removeAll()
        observeSettings()
        screen = .welcome
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    func handleEnded(_ message: String) {
        // A guest whose code didn't work goes straight back to typing it.
        let retryJoin = party?.role == .guest && !(party?.wasTogether ?? false) && !message.isEmpty
        party?.leave()
        party = nil
        cancellables.removeAll()
        observeSettings()
        notice = message.isEmpty ? nil : message
        screen = retryJoin ? .join : .welcome
    }

    private func runTypeTest(_ text: String) {
        screen = .join
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
            var delay = 0.0
            for ch in text {
                delay += 0.15
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    let keyCode: UInt16 = ch == "-" ? 27 : 0
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: String(ch),
                                                    charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: keyCode) {
                        window.sendEvent(event)
                    }
                }
            }
        }
    }

    static func requestPermissions(synthetic: Bool) async {
        guard !synthetic else { return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        _ = await AVCaptureDevice.requestAccess(for: .video)
    }
}
