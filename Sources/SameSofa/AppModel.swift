import AppKit
import AVFoundation
import Combine
import SameSofaCore
import SameSofaKit
import SwiftUI

/// Settings the user (well, the technical one of the two) can change.
final class AppSettings: ObservableObject {
    static let placeholderServer = "wss://CHANGE-ME.example"

    /// Baked in at build time by scripts/build.sh (SAMESOFA_SERVER_URL), else the placeholder.
    static var builtInServer: String {
        (Bundle.main.object(forInfoDictionaryKey: "SameSofaDefaultServerURL") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? placeholderServer
    }

    private let defaults = UserDefaults.standard
    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    @Published var stunURLs: String { didSet { defaults.set(stunURLs, forKey: "stunURLs") } }
    @Published var turnURL: String { didSet { defaults.set(turnURL, forKey: "turnURL") } }
    @Published var turnUsername: String { didSet { defaults.set(turnUsername, forKey: "turnUsername") } }
    @Published var turnCredential: String { didSet { defaults.set(turnCredential, forKey: "turnCredential") } }
    @Published var headphonesMode: Bool { didSet { defaults.set(headphonesMode, forKey: "headphonesMode") } }

    init() {
        serverURL = defaults.string(forKey: "serverURL") ?? AppSettings.builtInServer
        stunURLs = defaults.string(forKey: "stunURLs") ?? IceSettings.defaultSTUN.joined(separator: ", ")
        turnURL = defaults.string(forKey: "turnURL") ?? ""
        turnUsername = defaults.string(forKey: "turnUsername") ?? ""
        turnCredential = defaults.string(forKey: "turnCredential") ?? ""
        headphonesMode = defaults.bool(forKey: "headphonesMode")
        // A command-line override is handy for testing two copies on one Mac.
        if let override = LaunchOptions.shared.server { serverURL = override }
    }

    var isConfigured: Bool {
        guard let url = URL(string: serverURL), let scheme = url.scheme, ["ws", "wss"].contains(scheme) else { return false }
        return !serverURL.contains("CHANGE-ME")
    }

    var ice: IceSettings {
        IceSettings(stunURLs: stunURLs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                    turnURL: turnURL, turnUsername: turnUsername, turnCredential: turnCredential)
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
    /// Screenshots only: open on a given screen with a partly typed code.
    var screen: String?
    var prefill: String?
    /// Self-test: deliver these key presses to the join screen through the
    /// window (not the system), and record what code the app tried to join.
    var typeTest: String?
    var typeTestOutput: URL?

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
            case "--screen": screen = args.popFirst()
            case "--prefill": prefill = args.popFirst()
            case "--type-test": typeTest = args.popFirst()
            case "--type-test-output": typeTestOutput = args.popFirst().map { URL(fileURLWithPath: $0) }
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

    init() {
        DispatchQueue.main.async { self.runLaunchOptions() }
    }

    private func runLaunchOptions() {
        if let film = options.hostFilm { startHosting(film: film) }
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
        return PartySettings(serverURL: url, ice: settings.ice,
                             audioMode: synthetic ? .synthetic : (settings.headphonesMode ? .headphones : .voiceProcessing),
                             camera: synthetic ? .synthetic(label: options.label, hue: options.joinCode == nil ? 0.62 : 0.05) : .camera)
    }

    func chooseFilmAndHost() {
        let panel = NSOpenPanel()
        panel.title = "Choose a film to watch together"
        panel.prompt = "Watch this"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startHosting(film: url)
    }

    func startHosting(film: URL) {
        guard let ps = partySettings() else { return }
        notice = nil
        Task { @MainActor in
            await Self.requestPermissions(synthetic: options.synthetic)
            // Check the film plays at all before opening a room.
            let asset = AVURLAsset(url: film)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard playable else {
                self.notice = "That file can't be played by macOS (formats like MKV and AVI aren't supported yet). Try an MP4 or MOV file."
                return
            }
            let party = Party(role: .host, settings: ps)
            do {
                try party.host(film: film)
            } catch {
                self.notice = "Couldn't open that file: \(error.localizedDescription)"
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
        party.$phase.sink { [weak self] phase in
            guard let self else { return }
            if case .waitingForPartner(let code) = phase, let file = self.options.codeFile {
                try? code.write(to: file, atomically: true, encoding: .utf8)
            }
            if phase == .together, self.options.autoPlay, party.role == .host {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { party.playback.play() }
            }
        }.store(in: &cancellables)
        // Forward changes so views observing the model refresh.
        party.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    func leaveParty() {
        party?.leave()
        party = nil
        cancellables.removeAll()
        screen = .welcome
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    func handleEnded(_ message: String) {
        // A guest whose code didn't work goes straight back to typing it.
        let retryJoin = party?.role == .guest && !(party?.wasTogether ?? false) && !message.isEmpty
        party?.leave()
        party = nil
        cancellables.removeAll()
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
