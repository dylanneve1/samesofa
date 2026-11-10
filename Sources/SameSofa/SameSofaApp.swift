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
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

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
        .animation(.easeInOut(duration: 0.25), value: model.screen)
    }
}

enum Theme {
    static let background = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let card = Color.white.opacity(0.06)
    static let cardBorder = Color.white.opacity(0.09)
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.42) // warm lamp-light orange
    static let secondaryText = Color.white.opacity(0.6)
}
