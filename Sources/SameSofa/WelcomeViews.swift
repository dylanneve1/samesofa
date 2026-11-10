import AppKit
import SameSofaCore
import SwiftUI

struct Wordmark: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sofa.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Theme.accent)
            Text("SameSofa")
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text("Watch a film together, wherever you are.")
                .font(.title3)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 44) {
            Spacer()
            Wordmark()
            HStack(spacing: 22) {
                BigChoice(icon: "person.2.fill", title: "Join",
                          subtitle: "Your partner gives you a code", primary: true) {
                    model.screen = .join
                }
                .keyboardShortcut(.defaultAction)
                BigChoice(icon: "film.stack", title: "Host",
                          subtitle: "Pick a film on this Mac", primary: false) {
                    model.chooseFilmAndHost()
                }
            }
            if let notice = model.notice {
                NoticeView(text: notice)
            }
            Spacer()
            Text("Drop a film here to host it")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.3))
                .padding(.bottom, 22)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.startHosting(film: url) } }
            }
            return true
        }
    }
}

struct BigChoice: View {
    let icon: String
    let title: String
    let subtitle: String
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .medium))
                    .frame(height: 42)
                    .foregroundStyle(primary ? Color.black.opacity(0.8) : Theme.accent)
                Text(title)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(primary ? Color.black.opacity(0.6) : Theme.secondaryText)
            }
            .foregroundStyle(primary ? Color.black.opacity(0.85) : .white)
            .frame(width: 250, height: 190)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(primary ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.card))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(primary ? Color.clear : Theme.cardBorder, lineWidth: 1)
            )
            .scaleEffect(hovering ? 1.03 : 1)
            .shadow(color: primary ? Theme.accent.opacity(hovering ? 0.35 : 0.18) : .clear, radius: 24, y: 8)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

struct NoticeView: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.accent)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: 560)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

/// Six big boxes; typing anywhere fills them. Joins automatically on the sixth character.
struct JoinView: View {
    @EnvironmentObject var model: AppModel
    @State private var code = LaunchOptions.shared.prefill.map(RoomCode.sanitizeTyping) ?? ""

    var body: some View {
        VStack(spacing: 34) {
            Spacer()
            VStack(spacing: 10) {
                Text("Type the code")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Your partner can see it on their screen.")
                    .font(.title3)
                    .foregroundStyle(Theme.secondaryText)
            }
            ZStack {
                CodeKeyCatcher(code: $code, onSubmit: submit)
                    .frame(width: 1, height: 1)
                HStack(spacing: 12) {
                    ForEach(0..<RoomCode.length, id: \.self) { i in
                        CodeBox(character: character(at: i), active: i == min(code.count, RoomCode.length - 1))
                        if i == RoomCode.length / 2 - 1 { Spacer().frame(width: 14) }
                    }
                }
            }
            .onChange(of: code) { _, newValue in
                if newValue.count == RoomCode.length {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if code == newValue { submit() }
                    }
                }
            }
            if let notice = model.notice { NoticeView(text: notice) }
            HStack(spacing: 14) {
                Button {
                    model.notice = nil
                    model.screen = .welcome
                } label: {
                    Text("Back").frame(width: 110, height: 40)
                }
                .buttonStyle(SoftButtonStyle())
                Button {
                    submit()
                } label: {
                    Text("Join").fontWeight(.semibold).frame(width: 150, height: 40)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(code.count != RoomCode.length)
            }
            Spacer()
        }
        .padding(40)
    }

    private func submit() {
        guard code.count == RoomCode.length else { return }
        model.join(code: code)
    }

    private func character(at index: Int) -> String {
        guard index < code.count else { return "" }
        return String(code[code.index(code.startIndex, offsetBy: index)])
    }
}

struct CodeBox: View {
    let character: String
    let active: Bool

    var body: some View {
        Text(character)
            .font(.system(size: 44, weight: .semibold, design: .rounded))
            .frame(width: 72, height: 92)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(active ? Theme.accent : Theme.cardBorder, lineWidth: active ? 2 : 1)
            )
    }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3)
            .foregroundStyle(Color.black.opacity(0.85))
            .background(Capsule().fill(Theme.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)))
    }
}

struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
    }
}

/// Takes keyboard focus as soon as it is on screen and turns key presses
/// (and pasting) into a room code. No visible text field to click first.
struct CodeKeyCatcher: NSViewRepresentable {
    @Binding var code: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onChange = { code = $0 }
        view.onSubmit = onSubmit
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.current = code
        view.onChange = { code = $0 }
        view.onSubmit = onSubmit
    }

    final class CatcherView: NSView {
        var current = ""
        var onChange: ((String) -> Void)?
        var onSubmit: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { self.window?.makeFirstResponder(self) }
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 51, 117: // delete, forward delete
                if !current.isEmpty { current.removeLast(); onChange?(current) }
            case 36, 76: // return, enter
                onSubmit?()
            case 53: // escape clears
                current = ""; onChange?(current)
            default:
                guard let typed = event.characters else { return super.keyDown(with: event) }
                let next = RoomCode.sanitizeTyping(current + typed)
                if next != current { current = next; onChange?(current) } else { NSSound.beep() }
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" {
                paste(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        @objc func paste(_ sender: Any?) {
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            current = RoomCode.sanitizeTyping(text)
            onChange?(current)
        }
    }
}
