import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                TextField("Server address", text: $settings.serverURL, prompt: Text(AppSettings.placeholderServer))
                    .textFieldStyle(.roundedBorder)
                Text("The small room server that lets two copies of SameSofa find each other. Both of you need the same address. It never sees your film, voice or video.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Connection") }

            Section {
                Picker("Sound", selection: $settings.headphonesMode) {
                    Text("Speakers (echo cancellation on)").tag(false)
                    Text("Headphones (best film sound)").tag(true)
                }
                .pickerStyle(.radioGroup)
                Text("With speakers, SameSofa removes the film and your partner's voice from your microphone so they don't hear an echo. With headphones that isn't needed, and the film sounds better. Takes effect the next time you start or join.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Audio") }

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
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}
