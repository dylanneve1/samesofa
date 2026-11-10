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
    @State private var code = ""
    @FocusState private var focused: Bool

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
                // The real text field, invisible, keeps keyboard focus.
                TextField("", text: $code)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: code) { _, newValue in
                        let clean = RoomCode.sanitizeTyping(newValue)
                        if clean != newValue { code = clean }
                        if clean.count == RoomCode.length {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                if code == clean { model.join(code: clean) }
                            }
                        }
                    }
                    .onSubmit { if code.count == RoomCode.length { model.join(code: code) } }
                HStack(spacing: 12) {
                    ForEach(0..<RoomCode.length, id: \.self) { i in
                        CodeBox(character: character(at: i), active: focused && i == min(code.count, RoomCode.length - 1))
                        if i == RoomCode.length / 2 - 1 { Spacer().frame(width: 14) }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
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
                    model.join(code: code)
                } label: {
                    Text("Join").fontWeight(.semibold).frame(width: 150, height: 40)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(code.count != RoomCode.length)
            }
            Spacer()
        }
        .padding(40)
        .onAppear { focused = true }
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
