import AppKit
import SameSofaCore
import SameSofaKit
import SwiftUI

struct PartyView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var party: Party
    @ObservedObject var playback: PlaybackController

    @State private var controlsVisible = true
    @State private var lastActivity = Date()
    @State private var bubbleVisible = true
    @State private var bubbleLarge = false
    @State private var bubbleOffset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var scrubbing: Double?
    @State private var keyMonitor: Any?
    @State private var lastPointer: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                PlayerSurface(player: playback.player)
                    .opacity(playback.isLoaded ? 1 : 0)
                    .onTapGesture(count: 2) { toggleFullScreen() }
                    .onTapGesture { if party.phase == .together { playback.togglePlay() } }

                centerOverlay

                if party.phase == .together || party.remoteVideoTrack != nil {
                    bubble(in: geo.size)
                }

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    controlBar
                }
                .opacity(showChrome ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: showChrome)

                CursorHider(hidden: !showChrome).frame(width: 0, height: 0)
            }
            .onContinuousHover { phase in
                // Only real pointer movement counts; SwiftUI also reports hover on re-render.
                if case .active(let point) = phase {
                    if let last = lastPointer, abs(last.x - point.x) + abs(last.y - point.y) < 3 { return }
                    lastPointer = point
                    poke()
                }
            }
        }
        .ignoresSafeArea()
        .task {
            // Auto-hide the controls during playback after 3 s without mouse movement.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if controlsVisible, playback.intendsToPlay, !playback.isHeld,
                   Date().timeIntervalSince(lastActivity) > 3, scrubbing == nil {
                    controlsVisible = false
                }
            }
        }
        .onChange(of: party.phase) { _, phase in
            if case .ended(let message) = phase { model.handleEnded(message) }
        }
        .onAppear { installKeys() }
        .onDisappear { removeKeys() }
    }

    private var showChrome: Bool { controlsVisible || !playback.intendsToPlay || party.phase != .together }

    private func poke() {
        lastActivity = Date()
        if !controlsVisible { controlsVisible = true }
    }

    // MARK: Centre messages

    @ViewBuilder private var centerOverlay: some View {
        switch party.phase {
        case .creatingRoom, .joining:
            StatusCard {
                ProgressView().controlSize(.large)
                Text(party.role == .host ? "Opening a room…" : "Finding your partner…").font(.title2)
            }
        case .waitingForPartner(let code):
            WaitingForPartnerCard(code: code, filmName: party.filmName)
        case .connecting:
            StatusCard {
                ProgressView().controlSize(.large)
                Text("Connecting…").font(.title2)
            }
        case .together:
            if party.role == .guest && !playback.isLoaded {
                StatusCard {
                    Text("Getting the film ready").font(.title2)
                    ProgressView(value: party.transferFraction).frame(width: 260).tint(Theme.accent)
                }
            } else if playback.isHeld {
                StatusCard {
                    ProgressView()
                    Text(playback.localBuffering ? "Catching up — the film is still arriving…" : "Waiting for your partner to catch up…")
                        .font(.title3)
                }
            } else if !playback.intendsToPlay && playback.position < 0.5 {
                Button { playback.play() } label: {
                    Label("Play together", systemImage: "play.fill")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 30).padding(.vertical, 16)
                }
                .buttonStyle(AccentButtonStyle())
                .shadow(color: .black.opacity(0.5), radius: 20)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { model.leaveParty() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 36, height: 36)
            }
            .buttonStyle(CircleButtonStyle())
            .help("Leave")
            Text(party.filmName ?? "")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .shadow(radius: 4)
            Spacer()
            if party.hub.mode == .voiceProcessing, party.hub.voiceProcessingFailed {
                Label("Echo cancellation isn't available on this Mac. Headphones recommended.", systemImage: "headphones")
                    .font(.callout).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
            if party.phase == .together, party.role == .host, party.transferFraction < 1 {
                Text("Sending the film: \(Int(party.transferFraction * 100))%")
                    .font(.callout).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
        }
        .padding(.top, 30).padding(.horizontal, 22).padding(.bottom, 40)
        .background(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))
    }

    // MARK: Bottom controls

    private var controlBar: some View {
        let enabled = party.phase == .together || party.role == .host
        return VStack(spacing: 10) {
            ScrubBar(position: scrubbing ?? playback.position, duration: playback.duration,
                     available: party.role == .guest ? party.transferFraction : 1) { value, ended in
                scrubbing = ended ? nil : value
                if ended { playback.seek(to: value) }
                poke()
            }
            HStack(spacing: 14) {
                Button { playback.togglePlay() } label: {
                    Image(systemName: playback.intendsToPlay ? "pause.fill" : "play.fill")
                        .font(.system(size: 22)).frame(width: 46, height: 46)
                }
                .buttonStyle(CircleButtonStyle(prominent: true))
                .help(playback.intendsToPlay ? "Pause for both of you (space)" : "Play for both of you (space)")
                Button { playback.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 17)).frame(width: 38, height: 38)
                }.buttonStyle(CircleButtonStyle())
                Button { playback.skip(by: 10) } label: {
                    Image(systemName: "goforward.10").font(.system(size: 17)).frame(width: 38, height: 38)
                }.buttonStyle(CircleButtonStyle())
                Text("\(timeString(scrubbing ?? playback.position)) / \(timeString(playback.duration))")
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 10)
                VolumeControl(icon: "film", value: $party.filmVolume, help: "Film volume")
                VolumeControl(icon: "person.wave.2", value: $party.voiceVolume, help: "Your partner's voice")
                Divider().frame(height: 26).overlay(Color.white.opacity(0.2))
                ToggleButton(on: party.micOn, onIcon: "mic.fill", offIcon: "mic.slash.fill",
                             help: party.micOn ? "Mute your microphone" : "Unmute") { party.micOn.toggle() }
                ToggleButton(on: party.cameraOn, onIcon: "video.fill", offIcon: "video.slash.fill",
                             help: party.cameraOn ? "Turn your camera off" : "Turn your camera on") { party.cameraOn.toggle() }
                ToggleButton(on: bubbleVisible, onIcon: "person.crop.square.fill", offIcon: "person.crop.square",
                             help: bubbleVisible ? "Hide the video bubble" : "Show the video bubble") {
                    withAnimation(.spring(duration: 0.3)) { bubbleVisible.toggle() }
                }
                Button { toggleFullScreen() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 16)).frame(width: 38, height: 38)
                }
                .buttonStyle(CircleButtonStyle())
                .help("Full screen (F)")
            }
            .disabled(!enabled)
        }
        .padding(.horizontal, 26).padding(.top, 50).padding(.bottom, 22)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
    }

    // MARK: Video bubble

    private func bubbleSize(_ container: CGSize) -> CGSize {
        let width: CGFloat = bubbleLarge ? min(380, container.width * 0.4) : min(230, container.width * 0.28)
        return CGSize(width: width, height: width * 0.75)
    }

    @ViewBuilder private func bubble(in container: CGSize) -> some View {
        let size = bubbleSize(container)
        let margin: CGFloat = 22
        // Default spot: top-right corner, below the top bar.
        let base = CGPoint(x: container.width - size.width / 2 - margin, y: size.height / 2 + 80)
        let raw = CGPoint(x: base.x + bubbleOffset.width, y: base.y + bubbleOffset.height)
        let clamped = CGPoint(x: min(max(raw.x, size.width / 2 + 8), container.width - size.width / 2 - 8),
                              y: min(max(raw.y, size.height / 2 + 8), container.height - size.height / 2 - 8))
        if bubbleVisible {
            VideoBubble(party: party, size: size, large: $bubbleLarge, visible: $bubbleVisible)
                .position(clamped)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStart == nil { dragStart = bubbleOffset }
                            bubbleOffset = CGSize(width: dragStart!.width + value.translation.width,
                                                  height: dragStart!.height + value.translation.height)
                        }
                        .onEnded { _ in
                            dragStart = nil
                            // Keep the stored offset inside the window.
                            bubbleOffset = CGSize(width: clamped.x - base.x, height: clamped.y - base.y)
                        }
                )
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    // MARK: Helpers

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Leave typing in text fields alone.
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            switch event.keyCode {
            case 49: playback.togglePlay(); poke(); return nil            // space
            case 123: playback.skip(by: -10); poke(); return nil          // left
            case 124: playback.skip(by: 10); poke(); return nil           // right
            case 3: toggleFullScreen(); return nil                        // F
            case 46: party.micOn.toggle(); poke(); return nil             // M
            case 53:                                                      // esc
                if let w = NSApp.keyWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil); return nil }
                return event
            default: return event
            }
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

struct VideoBubble: View {
    @ObservedObject var party: Party
    let size: CGSize
    @Binding var large: Bool
    @Binding var visible: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            if party.partnerCameraOn, party.remoteVideoTrack != nil {
                RTCVideoSurface(track: party.remoteVideoTrack, cornerRadius: 18)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(white: 0.13))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: party.remoteVideoTrack == nil ? "person.fill" : "video.slash.fill")
                                .font(.system(size: 30))
                            Text(party.remoteVideoTrack == nil ? "Connecting camera…" : "Camera off").font(.callout)
                        }.foregroundStyle(.white.opacity(0.55))
                    )
            }
            // Self-view, bottom-right corner of the bubble.
            if party.cameraOn, party.localVideoTrack != nil {
                RTCVideoSurface(track: party.localVideoTrack, cornerRadius: 10, mirrored: true)
                    .frame(width: size.width * 0.3, height: size.width * 0.3 * 0.75)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 6)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            if !party.partnerMicOn {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 12, weight: .bold))
                    .padding(7)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .padding(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            if hovering {
                HStack(spacing: 6) {
                    Button { withAnimation(.spring(duration: 0.3)) { large.toggle() } } label: {
                        Image(systemName: large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(CircleButtonStyle())
                    .help(large ? "Smaller" : "Bigger")
                    Button { withAnimation(.spring(duration: 0.3)) { visible = false } } label: {
                        Image(systemName: "eye.slash").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(CircleButtonStyle())
                    .help("Hide (bring it back with the bubble button below)")
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 18, y: 6)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onTapGesture(count: 2) { withAnimation(.spring(duration: 0.3)) { large.toggle() } }
        .animation(.spring(duration: 0.3), value: size)
    }
}

struct WaitingForPartnerCard: View {
    let code: String
    let filmName: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Your code").font(.title3).foregroundStyle(Theme.secondaryText)
            Text(RoomCode.pretty(code))
                .font(.system(size: 64, weight: .bold, design: .rounded).monospaced())
                .tracking(6)
                .textSelection(.enabled)
            Text("Read it to your partner. They open SameSofa,\nchoose Join and type it in.")
                .multilineTextAlignment(.center)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.75))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 150, height: 36)
            }
            .buttonStyle(SoftButtonStyle())
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your partner…").foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 54).padding(.vertical, 40)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Theme.cardBorder))
        .shadow(color: .black.opacity(0.5), radius: 40)
    }
}

struct StatusCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 16) { content }
            .padding(.horizontal, 40).padding(.vertical, 30)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.cardBorder))
    }
}

struct CircleButtonStyle: ButtonStyle {
    var prominent = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white)
            .background(Circle().fill(prominent ? Theme.accent : Color.white.opacity(configuration.isPressed ? 0.28 : (hovering ? 0.2 : 0.12))))
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

struct ToggleButton: View {
    let on: Bool
    let onIcon: String
    let offIcon: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: on ? onIcon : offIcon)
                .font(.system(size: 16))
                .frame(width: 38, height: 38)
                .foregroundStyle(on ? .white : Color.black.opacity(0.85))
                .background(Circle().fill(on ? Color.white.opacity(0.12) : Color.white.opacity(0.85)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct VolumeControl: View {
    let icon: String
    @Binding var value: Float
    let help: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.white.opacity(0.8)).frame(width: 20)
            Slider(value: $value, in: 0...1).frame(width: 84).tint(Theme.accent).controlSize(.small)
        }
        .help(help)
    }
}

/// Thin timeline with a big invisible hit area.
struct ScrubBar: View {
    let position: Double
    let duration: Double
    /// Share of the film available locally (guest), drawn faintly.
    let available: Double
    let onScrub: (Double, Bool) -> Void
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18)).frame(height: hovering ? 7 : 5)
                Capsule().fill(Color.white.opacity(0.18)).frame(width: geo.size.width * available, height: hovering ? 7 : 5)
                Capsule().fill(Theme.accent).frame(width: max(0, geo.size.width * fraction), height: hovering ? 7 : 5)
                Circle().fill(.white).frame(width: hovering ? 16 : 12, height: hovering ? 16 : 12)
                    .offset(x: geo.size.width * fraction - (hovering ? 8 : 6))
                    .shadow(radius: 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in onScrub(value(at: v.location.x, width: geo.size.width), false) }
                .onEnded { v in onScrub(value(at: v.location.x, width: geo.size.width), true) })
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        }
        .frame(height: 22)
    }

    private func value(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width))) * duration
    }
}
