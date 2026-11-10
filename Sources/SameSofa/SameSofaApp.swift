import AppKit
import SwiftUI

@main
struct SameSofaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("SameSofa", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .preferredColorScheme(.dark)
                .frame(minWidth: 820, minHeight: 520)
                .modifier(LaunchWindowOpener())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) { InfoMenuItems() }
            CommandGroup(replacing: .help) { ShortcutsMenuItem() }
        }

        Window("About SameSofa", id: "about") {
            AboutView().preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView().preferredColorScheme(.dark)
        }
        .defaultSize(width: 680, height: 720)

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsView().preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(model.settings)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Started from a terminal (tests, screenshots): still behave like a normal app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch model.screen {
            case .welcome:
                WelcomeView().transition(.opacity)
            case .join:
                JoinView().transition(.opacity)
            case .party:
                if let party = model.party {
                    PartyView(party: party, playback: party.playback).transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: model.screen)
        .sheet(isPresented: firstLaunchNotice) { FirstLaunchNotice { noticeSeen = true } }
    }

    /// Shown once, on the first launch (never in test or screenshot runs).
    @AppStorage("firstLaunchNoticeSeen") private var noticeSeen = false
    private var firstLaunchNotice: Binding<Bool> {
        Binding(get: { !noticeSeen && !LaunchOptions.shared.isScripted }, set: { if !$0 { noticeSeen = true } })
    }
}

extension LaunchOptions {
    /// Started by a script or test (command-line switches), not by a person.
    var isScripted: Bool {
        server != nil || hostFilm != nil || joinCode != nil || synthetic || screen != nil || typeTest != nil || show != nil
    }
}

struct FirstLaunchNotice: View {
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sofa.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("Welcome to SameSofa").font(.title2.weight(.semibold))
            Text("SameSofa is free, open-source software provided as is, with no warranty. Only share films you have the right to share.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: done) { Text("OK").frame(width: 90) }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(30)
        .frame(width: 400)
    }
}

/// SameSofa ▸ About SameSofa, Acknowledgements…
struct InfoMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About SameSofa") { openWindow(id: "about") }
        Button("Acknowledgements…") { openWindow(id: "acknowledgements") }
    }
}

/// Help ▸ Keyboard Shortcuts
struct ShortcutsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
    }
}

/// Screenshots only (`--show about` and the like): opens a window without a click.
struct LaunchWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    func body(content: Content) -> some View {
        content.onAppear {
            switch LaunchOptions.shared.show {
            case "about": openWindow(id: "about")
            case "acknowledgements": openWindow(id: "acknowledgements")
            case "shortcuts": openWindow(id: "shortcuts")
            case "settings": openSettings()
            default: break
            }
        }
    }
}

enum Theme {
    static let background = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let card = Color.white.opacity(0.06)
    static let cardBorder = Color.white.opacity(0.09)
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.42) // warm lamp-light orange
    static let secondaryText = Color.white.opacity(0.6)
}
