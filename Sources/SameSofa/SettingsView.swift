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
                Text("The film always plays untouched, at full quality. With speakers, SameSofa removes the film and your partner's voice from your microphone so they hear no echo; with headphones that isn't needed. Automatic looks at the sound output in use.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Spatial audio", selection: $settings.systemSpatialAudio) {
                    Text("Off").tag(false)
                    Text("System").tag(true)
                }
                .pickerStyle(.segmented)
                Text("Off plays surround films as a plain, level-true downmix. System leaves Dolby Atmos and spatial audio to macOS; the film then can't be removed from your microphone, so use it with headphones. Takes effect with the next film.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Audio") }

            Section {
                Toggle("Match the display to the film's frame rate", isOn: $settings.matchFrameRate)
                Text("On displays with a variable refresh rate (ProMotion, adaptive sync), every film frame is shown for the same time. Displays fixed at 60 Hz can't do this for 24 fps films.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Video") }

            Section {
                TextField("Server address", text: $settings.serverURL, prompt: Text(AppSettings.placeholderServer))
                    .textFieldStyle(.roundedBorder)
                Text("The small room server that lets two copies of SameSofa find each other. Both of you need the same address. It never sees your film, voice or video.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Connection") }

            Section {
                TextField("STUN servers (comma separated)", text: $settings.stunURLs)
                    .textFieldStyle(.roundedBorder)
                TextField("TURN server (e.g. turn:turn.example.org:3478)", text: $settings.turnURL)
                    .textFieldStyle(.roundedBorder)
                TextField("TURN username", text: $settings.turnUsername)
                    .textFieldStyle(.roundedBorder)
                SecureField("TURN password", text: $settings.turnCredential)
                    .textFieldStyle(.roundedBorder)
                Text("Only needed if the two of you can't connect directly (some office, hotel or mobile networks). A TURN server relays the encrypted connection.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Advanced networking") }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 720)
        .padding(.vertical, 8)
    }
}
