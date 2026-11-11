import SameSofaKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Headphones", selection: $settings.soundOutput) {
                    Text("Automatic").tag("automatic")
                    Text("On").tag("headphones")
                    Text("Off").tag("speakers")
                }
                .pickerStyle(.segmented)
                .help("Automatic decides from the sound output in use")
                Text("The film always plays untouched, at full quality. With speakers, SameSofa removes the film and your partner's voice from your microphone so they hear no echo; with headphones that isn't needed. Automatic looks at the sound output in use.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Spatial audio", selection: $settings.systemSpatialAudio) {
                    Text("Off").tag(false)
                    Text("System").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Takes effect with the next film")
                Text("Off plays surround films as a plain, level-true downmix. System leaves Dolby Atmos and spatial audio to macOS; the film then can't be removed from your microphone, so use it with headphones. Takes effect with the next film.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Audio") }

            Section {
                Toggle("Match the display to the film's frame rate", isOn: $settings.matchFrameRate)
                    .help("For displays with a variable refresh rate")
                Text("On displays with a variable refresh rate (ProMotion, adaptive sync), every film frame is shown for the same time.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Match display to film in full screen", selection: $settings.displayMatch) {
                    Text("Automatic").tag("automatic")
                    Text("Off").tag("off")
                }
                .pickerStyle(.segmented)
                .help("Automatic switches a fixed-rate display in full screen and back again")
                Text("For displays with a fixed refresh rate, such as most TVs and monitors. A 24 fps film can't be shown evenly at 60 Hz. In full screen, Automatic switches the display to a rate that suits the film (24 or 120 Hz, say) if it offers one at the same resolution, and switches back when you leave full screen. The screen may go black for a moment while it changes.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Video") }

            Section {
                Picker("Keep films to resume them", selection: $settings.keepFilmsGB) {
                    Text("Off").tag(0.0)
                    Text("5 GB").tag(5.0)
                    Text("20 GB").tag(20.0)
                    Text("50 GB").tag(50.0)
                }
                .pickerStyle(.segmented)
                .help("How much disk space films kept for resuming may take")
                Text("A film your partner shares stays on this Mac for 24 hours, so that if you watch it again (or the app is reopened in the middle) only the missing part is sent. Films you converted to share are kept the same way. The oldest go first when the limit is reached.")
                    .font(.caption).foregroundStyle(.secondary)
                KeptFilmsRow()
            } header: { Text("Films") }

            Section {
                TextField("Server address", text: $settings.serverURL, prompt: Text(AppSettings.placeholderServer))
                    .textFieldStyle(.roundedBorder)
                    .help("Looks like wss://sofa.example.org. Both of you need the same one.")
                Text("The small room server that lets two copies of SameSofa find each other. Both of you need the same address. It never sees your film, voice or video.")
                    .font(.caption).foregroundStyle(.secondary)
                ConnectionTestRow()
            } header: { Text("Connection") }

            Section {
                TextField("STUN servers (comma separated)", text: $settings.stunURLs)
                    .textFieldStyle(.roundedBorder)
                    .help("Servers that tell each Mac its public address. The default ones are fine.")
                TextField("TURN server (e.g. turn:turn.example.org:3478)", text: $settings.turnURL)
                    .textFieldStyle(.roundedBorder)
                    .help("A relay for networks that block direct connections. Starts with turn: or turns:")
                TextField("TURN username", text: $settings.turnUsername)
                    .textFieldStyle(.roundedBorder)
                    .help("The user name for the TURN server above")
                SecureField("TURN password", text: $settings.turnCredential)
                    .textFieldStyle(.roundedBorder)
                    .help("The password for the TURN server above")
                Text("Only needed if the two of you can't connect directly (some office, hotel or mobile networks). A TURN server relays the encrypted connection."
                     + (AppSettings.builtInRelay != nil ? " This copy of SameSofa comes with a relay; it is used while the TURN server field is empty." : ""))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Advanced networking") }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 780)
        .padding(.vertical, 8)
    }
}

/// How much the kept films take, and a button to remove them now.
struct KeptFilmsRow: View {
    @State private var bytes: Int64 = 0
    @State private var cleared = false

    var body: some View {
        HStack(spacing: 10) {
            Button("Remove kept films now") {
                DispatchQueue.global(qos: .userInitiated).async {
                    FilmCache.shared.clear()
                    let left = FilmCache.shared.totalBytes
                    DispatchQueue.main.async { bytes = left; cleared = true }
                }
            }
            .disabled(bytes == 0)
            .accessibilityHint("Deletes the films kept for resuming, except one being watched right now")
            Text(bytes == 0 ? (cleared ? "Removed." : "Nothing is kept at the moment.")
                 : "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) kept at the moment.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let now = FilmCache.shared.totalBytes
                DispatchQueue.main.async { bytes = now }
            }
        }
    }
}

/// "Test connection": the room server, and the TURN relay if there is one. One line each.
struct ConnectionTestRow: View {
    @EnvironmentObject var settings: AppSettings
    @State private var running = false
    @State private var result: ConnectionTester.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("Test connection") { run() }
                    .disabled(running)
                    .accessibilityHint("Checks the room server and, if one is set, the TURN relay")
                if running {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("Testing…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result {
                line(result.server)
                if let relay = result.relay {
                    line(relay)
                } else {
                    Text("Relay (TURN): none set. Most connections work without one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            // Screenshot runs: press the button without a click.
            if LaunchOptions.shared.testConnectionOutput != nil, result == nil, !running { run() }
        }
        // A changed address makes the old answer stale.
        .onChange(of: settings.serverURL) { result = nil }
        .onChange(of: settings.turnURL) { result = nil }
    }

    private func line(_ line: ConnectionTester.Line) -> some View {
        Label {
            Text(line.text).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } icon: {
            Image(systemName: line.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(line.ok ? Color.green : Color.orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((line.ok ? "Passed. " : "Failed. ") + line.text)
        .accessibilityAddTraits(.isStaticText)
    }

    private func run() {
        running = true
        result = nil
        ConnectionTester.run(serverURL: settings.serverURL, ice: settings.ice) { outcome in
            result = outcome
            running = false
            if let path = LaunchOptions.shared.testConnectionOutput {
                let text = [outcome.server.text, outcome.relay?.text ?? "Relay (TURN): none set."].joined(separator: "\n")
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}
