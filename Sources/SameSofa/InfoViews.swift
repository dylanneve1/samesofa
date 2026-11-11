import AppKit
import SwiftUI

// About, Acknowledgements and Keyboard Shortcuts: small windows in the app's
// own dark style. The licence texts themselves come from the files that ship
// inside the app (LICENSE, THIRD-PARTY-NOTICES.md, the FFmpeg build record),
// so what is shown is always what is distributed.

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    /// Baked in at build time (SAMESOFA_PROJECT_URL), like the server address.
    static var projectURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "SameSofaProjectURL") as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    static func resource(_ name: String, _ ext: String?, subdirectory: String? = nil) -> String? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static var licence: String { resource("LICENSE", nil) ?? "MIT No Attribution (MIT-0). See LICENSE in SameSofa's source code." }
    static var notices: String { resource("THIRD-PARTY-NOTICES", "md") ?? "The notices are in THIRD-PARTY-NOTICES.md in SameSofa's source code." }
    static var disclaimer: String { resource("DISCLAIMER", "md") ?? "SameSofa is provided as is, without warranty. Only share films you have the right to share." }
    static var ffmpegBuild: String? { resource("BUILDINFO", "txt", subdirectory: "FFmpeg") }
    static var audioProcessingBuild: String? { resource("BUILDINFO", "txt", subdirectory: "APM") }

    /// The part of the notices under a heading ("## FFmpeg", "### dav1d"), up to the next heading named in `until`.
    static func noticeSection(_ heading: String, until: [String] = ["## "]) -> String {
        var lines: [Substring] = [], inside = false
        for line in notices.split(separator: "\n", omittingEmptySubsequences: false) {
            if inside, until.contains(where: { line.hasPrefix($0) }) { break }
            if line == heading { inside = true; continue }
            if inside { lines.append(line) }
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct InfoCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.cardBorder))
    }
}

struct LicenceTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Theme.accent.opacity(0.18)))
            .foregroundStyle(Theme.accent)
    }
}

// MARK: About

struct AboutView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var showDisclaimer = false

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            Text("SameSofa").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Version \(AppInfo.version)" + (AppInfo.build.isEmpty ? "" : " (\(AppInfo.build))"))
                .font(.callout.monospacedDigit()).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
            Text("Watch a film together from two Macs, in sync, with each other's face and voice alongside.")
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("Free, open-source software under the MIT-0 licence, provided as is, without warranty. Only share films you have the right to share.")
                .font(.callout).foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let url = AppInfo.projectURL {
                    Link(destination: url) { Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right").frame(height: 30).padding(.horizontal, 12) }
                        .buttonStyle(SoftButtonStyle())
                        .accessibilityHint("Opens the project's page in your browser")
                }
                Button { showDisclaimer = true } label: { Label("Disclaimer", systemImage: "doc.text").frame(height: 30).padding(.horizontal, 12) }
                    .buttonStyle(SoftButtonStyle())
                    .accessibilityHint("Shows the full text")
                Button { openWindow(id: "acknowledgements") } label: { Label("Acknowledgements", systemImage: "heart").frame(height: 30).padding(.horizontal, 12) }
                    .buttonStyle(SoftButtonStyle())
                    .accessibilityHint("Opens the list of projects SameSofa is built on, with their licences")
            }
            .fixedSize()
            .padding(.top, 4)
            Text("How a film is being played (codec, bit rate, sound path, display) is shown by the ⓘ button in the playback controls.")
                .font(.caption).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(30)
        .frame(width: 560)
        .background(Theme.background)
        .sheet(isPresented: $showDisclaimer) { TextSheet(title: "Disclaimer", text: AppInfo.disclaimer) { showDisclaimer = false } }
    }
}

/// Full text, monospaced, selectable, scrollable.
struct TextSheet: View {
    let title: String
    let text: String
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .accessibilityLabel("Copy the text")
                .accessibilityHint("Puts the whole text of \(title) on the clipboard")
                Button("Done", action: done).keyboardShortcut(.defaultAction)
                    .accessibilityHint("Closes this text")
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35)))
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }
}

// MARK: Acknowledgements

struct Acknowledgement: Identifiable {
    let name: String
    let use: String
    let licence: String
    let link: String?
    /// Extra facts shown on the card (version, build, where the source is).
    var facts: [String] = []
    let text: () -> String
    var id: String { name }
}

struct AcknowledgementsView: View {
    @State private var shown: Acknowledgement?
    @State private var copied = false

    static var components: [Acknowledgement] {
        var ffmpegFacts = [
            "Runs as separate helper programs (ffmpeg, ffprobe in SameSofa.app/Contents/Helpers, their libraries in Contents/Frameworks); nothing of FFmpeg is linked into SameSofa itself.",
            "You may replace the helper with your own build of the same FFmpeg version: swap those files. scripts/build-ffmpeg.sh in SameSofa's source code is the exact build recipe and downloads the corresponding source.",
        ]
        if let build = AppInfo.ffmpegBuild {
            let lines = build.split(separator: "\n").map(String.init)
            ffmpegFacts.insert(contentsOf: lines.prefix(4), at: 0)
        }
        return [
            Acknowledgement(name: "SameSofa", use: "This app. Its own code is yours to use, change and share.", licence: "MIT-0",
                            link: AppInfo.projectURL?.absoluteString, text: { AppInfo.licence }),
            Acknowledgement(name: "WebRTC", use: "The call: camera, voice and the encrypted connection that also carries the film.",
                            licence: "BSD-3-Clause + patent grant", link: "https://webrtc.org",
                            facts: ["Milestone 157, prebuilt framework from github.com/stasel/WebRTC, unmodified."],
                            text: { AppInfo.noticeSection("## WebRTC") }),
            Acknowledgement(name: "WebRTC audio processing", use: "Keeps the film and your partner's voice out of your microphone (echo cancellation), and cleans up background noise.",
                            licence: "BSD-3-Clause", link: "https://www.freedesktop.org/software/pulseaudio/webrtc-audio-processing/",
                            facts: (AppInfo.audioProcessingBuild?.split(separator: "\n").prefix(3).map(String.init) ?? []),
                            text: { AppInfo.noticeSection("## WebRTC audio processing") }),
            Acknowledgement(name: "Abseil", use: "Support library used by the audio processing.", licence: "Apache-2.0", link: "https://abseil.io",
                            text: { AppInfo.noticeSection("## Abseil") }),
            Acknowledgement(name: "FFmpeg", use: "On the host's Mac: reads MKV, AVI, WebM and other files, converts or repairs them into something both Macs can play.",
                            licence: "LGPL-2.1-or-later", link: "https://ffmpeg.org", facts: ffmpegFacts,
                            text: { AppInfo.noticeSection("## FFmpeg", until: ["## ", "### dav1d"]) + (AppInfo.ffmpegBuild.map { "\n\n── Build record ──\n\n" + $0 } ?? "") }),
            Acknowledgement(name: "dav1d", use: "Decodes AV1 video inside the FFmpeg helper.", licence: "BSD-2-Clause",
                            link: "https://code.videolan.org/videolan/dav1d", text: { AppInfo.noticeSection("### dav1d") }),
            Acknowledgement(name: "ws", use: "WebSocket library of the small room server. Not part of this app.", licence: "MIT",
                            link: "https://github.com/websockets/ws", text: { AppInfo.noticeSection("## ws") }),
            Acknowledgement(name: "SF Symbols", use: "The icons, provided by macOS.", licence: "Apple", link: "https://developer.apple.com/sf-symbols/",
                            text: { "SF Symbols are provided by macOS and used under Apple's terms for apps running on Apple platforms." }),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Acknowledgements").font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("SameSofa stands on the work of these projects. Thank you to everyone behind them.")
                            .foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 20)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AppInfo.licence + "\n\n" + AppInfo.notices + (AppInfo.ffmpegBuild.map { "\n\nFFmpeg build record\n\n" + $0 } ?? ""), forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy all notices", systemImage: copied ? "checkmark" : "doc.on.doc").frame(height: 30).padding(.horizontal, 12)
                    }
                    .buttonStyle(SoftButtonStyle())
                    .accessibilityHint("Puts SameSofa's licence and every third-party notice on the clipboard")
                }
                ForEach(Self.components) { component in
                    InfoCard {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(component.name).font(.headline)
                            LicenceTag(text: component.licence)
                            Spacer()
                        }
                        Text(component.use).fixedSize(horizontal: false, vertical: true)
                        ForEach(component.facts, id: \.self) { fact in
                            Text(fact).font(.caption).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        HStack(spacing: 16) {
                            Button("View licence") { shown = component }.buttonStyle(.link)
                                .accessibilityLabel("View the licence of \(component.name)")
                                .accessibilityHint("Shows the full licence text")
                            if let link = component.link, let url = URL(string: link) {
                                Link("Project website", destination: url)
                                    .accessibilityLabel("\(component.name) website")
                                    .accessibilityHint("Opens in your browser")
                            }
                        }
                        .font(.callout)
                        .padding(.top, 2)
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(Theme.background)
        .sheet(item: $shown) { component in
            TextSheet(title: "\(component.name) · \(component.licence)", text: component.text()) { shown = nil }
        }
    }
}

// MARK: Keyboard shortcuts

struct ShortcutsView: View {
    static let shortcuts: [(String, String)] = [
        ("Space", "Play or pause for both of you"),
        ("←  →", "Back or forward 10 seconds"),
        ("F", "Full screen"),
        ("M", "Mute or unmute your microphone"),
        ("Esc", "Leave full screen"),
        ("⌘O", "Choose a film (the host; the call goes on)"),
        ("⇧⌘W", "Close the film, stay in the room (the host)"),
    ]
    /// How VoiceOver should say the keys.
    static let spoken = ["Space": "Space bar", "←  →": "Left arrow and right arrow", "F": "F", "M": "M", "Esc": "Escape",
                         "⌘O": "Command O", "⇧⌘W": "Shift Command W"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard shortcuts").font(.system(size: 22, weight: .bold, design: .rounded))
            InfoCard {
                ForEach(Self.shortcuts, id: \.0) { key, action in
                    HStack(spacing: 14) {
                        Text(key)
                            .font(.system(size: 13, weight: .semibold, design: .rounded).monospaced())
                            .frame(width: 64, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
                        Text(action)
                        Spacer()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Self.spoken[key] ?? key): \(action)")
                    .accessibilityAddTraits(.isStaticText)
                }
            }
            Text("Play, pause and seeking work while a film is open and always apply to both of you. Changing or closing the film never ends the call; only Leave does.")
                .font(.callout).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 420)
        .background(Theme.background)
    }
}
