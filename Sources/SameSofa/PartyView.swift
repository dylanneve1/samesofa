import AppKit
import SameSofaCore
import SameSofaKit
import SwiftUI

struct PartyView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var party: Party
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject var settings: AppSettings
    @State private var showQuality = LaunchOptions.shared.show == "quality"
    @State private var versionNoteDismissed = false

    @State private var controlsVisible = true
    @State private var lastActivity = Date()
    @State private var bubbleVisible = true
    @State private var bubbleLarge = false
    @State private var bubbleOffset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var scrubbing: Double?
    @State private var keyMonitor: Any?
    @State private var lastPointer: CGPoint?

    /// The film has the window: it is loaded and can be shown. Until then (no
    /// film, one being chosen, prepared or fetched) the call has it.
    private var filmOnScreen: Bool { party.sharedFilm != nil && playback.isLoaded }
    private var together: Bool { party.phase == .together }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if filmOnScreen { Color.black } else { Theme.background }
                PlayerSurface(player: playback.player, frameRate: playback.frameRate,
                              playing: playback.intendsToPlay && !playback.isHeld, matchFrameRate: settings.matchFrameRate)
                    .opacity(filmOnScreen ? 1 : 0)
                    .allowsHitTesting(filmOnScreen)
                    .onTapGesture(count: 2) { toggleFullScreen() }
                    .onTapGesture { if party.phase == .together { playback.togglePlay() } }

                if together && !filmOnScreen {
                    // Just the two of you: your partner has the window.
                    HangoutView(party: party, playback: playback, hadFilm: hadFilm) { model.chooseFilm() } closeFilm: { model.closeFilm() }
                        .transition(.opacity)
                }

                centerOverlay

                if filmOnScreen, party.phase == .together || party.remoteVideoTrack != nil {
                    bubble(in: geo.size)
                }

                if filmOnScreen, let next = party.nextCard {
                    // The film is over and another one is queued: it starts by itself unless one of the two says no.
                    NextCardView(card: next, isHost: party.role == .host, cancel: { party.cancelNext() }, playNow: { party.playNext() })
                        .padding(.trailing, 26).padding(.bottom, 118)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if filmOnScreen { controlBar }
                }
                .opacity(showChrome ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: showChrome)

                CursorHider(hidden: !showChrome).frame(width: 0, height: 0)
            }
            .animation(.easeInOut(duration: 0.35), value: filmOnScreen)
            .animation(.spring(duration: 0.35), value: party.nextCard)
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
        // The host drops another film on the window: it replaces the film, the call goes on.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard model.canChooseFilm, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.openFilm(url) } }
            }
            return true
        }
        .task {
            // Auto-hide the controls during playback after 3 s without mouse movement.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if controlsVisible, filmOnScreen, playback.intendsToPlay, !playback.isHeld,
                   Date().timeIntervalSince(lastActivity) > 3, scrubbing == nil {
                    controlsVisible = false
                }
            }
        }
        .onChange(of: party.phase) { _, phase in
            if case .ended(let message) = phase { model.handleEnded(message) }
        }
        .onChange(of: party.sharedFilm != nil) { _, has in
            if has { hadFilm = true }
            // A new film (or none): the controls are there again.
            controlsVisible = true
            lastActivity = Date()
        }
        .onAppear {
            if party.sharedFilm != nil { hadFilm = true }
            installKeys()
        }
        .onDisappear { removeKeys() }
    }

    /// A film has been on in this room already (the next one is "another film").
    @State private var hadFilm = false
    @State private var showQueue = LaunchOptions.shared.show == "queue"

    private var showChrome: Bool { !filmOnScreen || controlsVisible || !playback.intendsToPlay || showQuality }

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
            // While the host watches alone, the picture stays clear: the code
            // moves to a chip in the top bar and the card returns on pause.
            if !filmOnScreen || !playback.intendsToPlay {
                WaitingForPartnerCard(code: code, hasFilm: party.sharedFilm != nil, choosing: party.choosingFilm,
                                      preparing: party.preparing, notice: party.filmNotice,
                                      chooseFilm: { model.chooseFilm() }, cancel: { model.closeFilm() })
            }
        case .connecting:
            StatusCard {
                if party.connectionFailed {
                    Text("Couldn't connect directly").font(.title2)
                    Text("This usually means one of your networks blocks it. A relay server fixes that (Settings ▸ Connection).")
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                    HStack(spacing: 12) {
                        Button("Leave") { model.leaveParty() }
                        Button("Try again") { party.retryConnection() }.buttonStyle(.borderedProminent)
                            .accessibilityHint("Connects again in the same room")
                    }
                } else {
                    ProgressView().controlSize(.large)
                    Text("Connecting…").font(.title2)
                }
            }
        case .together where party.reconnecting:
            let hasFilm = party.sharedFilm != nil
            StatusCard {
                if party.connectionFailed {
                    Text("Couldn't reconnect").font(.title2)
                    Text(hasFilm ? "Check the internet connection on both Macs, then try again. The film stays where it was, and what has already arrived is kept."
                         : "Check the internet connection on both Macs, then try again.")
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
                } else {
                    ProgressView().controlSize(.large).accessibilityHidden(true)
                    Text("Connection lost").font(.title2)
                    Text(hasFilm ? "Trying to reconnect… The film waits, and what has already arrived is kept." : "Trying to reconnect…")
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
                }
                HStack(spacing: 12) {
                    Button { model.leaveParty() } label: { Text("Leave").frame(width: 110, height: 36) }
                        .buttonStyle(SoftButtonStyle())
                    Button { party.retryConnection() } label: { Text("Try again").fontWeight(.semibold).frame(width: 130, height: 36) }
                        .buttonStyle(AccentButtonStyle())
                        .accessibilityHint("Connects again in the same room")
                }
                .padding(.top, 4)
            }
        case .together where filmOnScreen:
            if playback.isHeld {
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
            // The only thing that ends the call. Closing or changing the film does not.
            Button { model.leaveParty() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 13, weight: .semibold))
                    Text("Leave").font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 14).frame(height: 36)
            }
            .buttonStyle(PillButtonStyle())
            .help(party.role == .host ? "Leave and close the room" : "Leave the room")
            .accessibilityLabel("Leave")
            .accessibilityHint(party.role == .host ? "Ends the call and closes the room" : "Ends the call")
            if filmOnScreen {
                Text(party.filmName ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .shadow(radius: 4)
                    .padding(.leading, 4)
                if party.role == .host {
                    Button { model.chooseFilm() } label: {
                        Label("Change film", systemImage: "film.stack").font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 32)
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!party.canChangeFilm)
                    .help(party.canChangeFilm ? "Watch another film. The call goes on. (⌘O)" : "Your partner needs SameSofa 1.3 for changing film")
                    Button { model.closeFilm() } label: {
                        Label("Close film", systemImage: "xmark").font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 32)
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!party.canChangeFilm)
                    .help(party.canChangeFilm ? "Stop watching this film. The call goes on. (⇧⌘W)" : "Your partner needs SameSofa 1.3 for closing the film")
                    Button { showQueue.toggle() } label: {
                        Label(party.queue.isEmpty ? "Up next" : "Up next · \(party.queue.count)", systemImage: "list.bullet")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 32)
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!party.canQueue)
                    .help(party.canQueue ? "What follows when this film ends" : "Your partner needs SameSofa 1.3 for a queue of films")
                    .accessibilityLabel(party.queue.isEmpty ? "Up next" : "Up next, \(party.queue.count) queued")
                    .popover(isPresented: $showQueue, arrowEdge: .bottom) {
                        UpNextView(party: party, add: { model.addToQueue() })
                    }
                } else if let next = party.upNextName {
                    Text("Next: \(next)")
                        .font(.callout).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.45)))
                        .accessibilityLabel("Up next: \(next)")
                }
            }
            Spacer()
            if case .waitingForPartner(let code) = party.phase, filmOnScreen { CodeChip(code: code) }
            if party.phase == .together, let note = party.versionNote, !versionNoteDismissed {
                // Not in the way of anything: a line in the top bar that goes away on a click.
                Button { versionNoteDismissed = true } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle").padding(.top, 1).accessibilityHidden(true)
                        Text(note).lineLimit(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 400)
                .help("Click to hide this note")
                .accessibilityLabel(note)
                .accessibilityHint("Hides this note")
            }
            if filmOnScreen, party.phase == .together, party.transferFraction < 1, let film = party.sharedFilm {
                Text(party.transferLine.isEmpty ? TransferText.line(sending: party.role == .host, received: 0, total: film.size, rate: 0) : party.transferLine)
                    .font(.callout).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
        }
        .padding(.top, 30).padding(.horizontal, 22).padding(.bottom, 40)
        .background(LinearGradient(colors: [.black.opacity(filmOnScreen ? 0.65 : 0), .clear], startPoint: .top, endPoint: .bottom))
        .onChange(of: party.versionNote) { _, _ in versionNoteDismissed = false }
    }

    // MARK: Bottom controls

    private var controlBar: some View {
        let enabled = (party.phase == .together || party.role == .host) && filmOnScreen
        return VStack(spacing: 10) {
            ScrubBar(position: scrubbing ?? playback.position, duration: playback.duration,
                     available: party.role == .guest ? party.transferFraction : 1,
                     ranges: party.transferFraction < 1 ? party.receivedRanges : []) { value, ended in
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
                .accessibilityLabel(playback.intendsToPlay ? "Pause" : "Play")
                Button { playback.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 17)).frame(width: 38, height: 38)
                }.buttonStyle(CircleButtonStyle()).help("Back 10 seconds (←)").accessibilityLabel("Back 10 seconds")
                Button { playback.skip(by: 10) } label: {
                    Image(systemName: "goforward.10").font(.system(size: 17)).frame(width: 38, height: 38)
                }.buttonStyle(CircleButtonStyle()).help("Forward 10 seconds (→)").accessibilityLabel("Forward 10 seconds")
                Text("\(timeString(scrubbing ?? playback.position)) / \(timeString(playback.duration))")
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 10)
                VolumeControl(icon: "film", value: $party.filmVolume, help: "Film volume")
                VolumeControl(icon: "person.wave.2", value: $party.voiceVolume, help: "Your partner's voice")
                Divider().frame(height: 26).overlay(Color.white.opacity(0.2))
                if playback.hasSubtitles {
                    ToggleButton(on: playback.subtitlesOn, onIcon: "captions.bubble.fill", offIcon: "captions.bubble",
                                 help: playback.subtitlesOn ? "Hide subtitles" : "Show subtitles") { playback.setSubtitles(!playback.subtitlesOn) }
                }
                ToggleButton(on: party.micOn, onIcon: "mic.fill", offIcon: "mic.slash.fill",
                             help: party.micOn ? "Mute your microphone" : "Unmute") { party.micOn.toggle() }
                ToggleButton(on: party.cameraOn, onIcon: "video.fill", offIcon: "video.slash.fill",
                             help: party.cameraOn ? "Turn your camera off" : "Turn your camera on") { party.cameraOn.toggle() }
                ToggleButton(on: bubbleVisible, onIcon: "person.crop.square.fill", offIcon: "person.crop.square",
                             help: bubbleVisible ? "Hide the video bubble" : "Show the video bubble") {
                    withAnimation(.spring(duration: 0.3)) { bubbleVisible.toggle() }
                }
                Button { showQuality.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 17)).frame(width: 38, height: 38)
                }
                .buttonStyle(CircleButtonStyle())
                .help("Playback quality")
                .accessibilityLabel("Playback quality")
                .popover(isPresented: $showQuality, arrowEdge: .top) { QualityView(party: party, playback: playback) }
                Button { toggleFullScreen() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 16)).frame(width: 38, height: 38)
                }
                .buttonStyle(CircleButtonStyle())
                .help("Full screen (F)")
                .accessibilityLabel("Full screen")
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
            // Shortcuts with Command (⌘O, ⇧⌘W, ...) belong to the menus.
            if event.modifierFlags.contains(.command) { return event }
            let film = party.sharedFilm != nil && playback.isLoaded
            switch event.keyCode {
            case 49: if film { playback.togglePlay(); poke(); return nil }; return event   // space
            case 123: if film { playback.skip(by: -10); poke(); return nil }; return event // left
            case 124: if film { playback.skip(by: 10); poke(); return nil }; return event  // right
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

/// Host: the film is being converted to MP4 before it can be shared.
struct PreparingView: View {
    let preparing: Preparing
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("Preparing film… \(Int(preparing.fraction * 100))%")
                .font(.title2.monospacedDigit())
            ProgressView(value: preparing.fraction).frame(width: 280).tint(Theme.accent)
            Text(preparing.repairingTiming
                 ? (preparing.remuxOnly
                    ? "This file's timing information is damaged. Repairing it; no quality is lost."
                    : "This file's timing information is damaged and couldn't be repaired. Converting the picture instead.")
                 : (preparing.remuxOnly
                    ? "Rewrapping it for macOS. No quality is lost."
                    : "Converting it for macOS with this Mac's video encoder."))
                .font(.callout).foregroundStyle(Theme.secondaryText)
            Button(action: cancel) { Text("Cancel").frame(width: 120, height: 34) }
                .buttonStyle(SoftButtonStyle()).padding(.top, 4)
        }
    }
}

struct WaitingForPartnerCard: View {
    let code: String
    /// A film is loaded already (the host can watch while waiting).
    var hasFilm = false
    /// The film that was picked is being looked at.
    var choosing = false
    var preparing: Preparing?
    /// Why the film that was picked can't be watched.
    var notice: String?
    var chooseFilm: () -> Void = {}
    var cancel: () -> Void = {}
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
            Label(hasFilm ? "Waiting for your partner. You can start watching meanwhile."
                  : "Waiting for your partner. You don't need a film to start: choose one now or later.", systemImage: "person.2")
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let preparing {
                Divider().overlay(Color.white.opacity(0.15)).frame(width: 300)
                PreparingView(preparing: preparing, cancel: cancel)
            } else if choosing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("Looking at the film…").foregroundStyle(Theme.secondaryText)
                }
            } else if !hasFilm {
                if let notice { NoticeView(text: notice) }
                Button(action: chooseFilm) {
                    Label("Choose a film", systemImage: "film.stack").fontWeight(.semibold).frame(width: 200, height: 42)
                }
                .buttonStyle(AccentButtonStyle())
                .accessibilityHint("Picks a film on this Mac to watch together")
            }
        }
        .padding(.horizontal, 54).padding(.vertical, 40)
        .frame(maxWidth: 640)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.black.opacity(0.4)))
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
            // Dark enough to read on a bright film.
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.45)))
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

/// "Next: <name>, starts in 5 s": shown to both when a film has ended and another one is queued.
struct NextCardView: View {
    let card: NextCard
    let isHost: Bool
    let cancel: () -> Void
    let playNow: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let left = max(0, card.deadline.timeIntervalSince(context.date))
            VStack(alignment: .leading, spacing: 10) {
                Text("UP NEXT").font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(Theme.accent)
                Text(card.name).font(.system(size: 20, weight: .semibold, design: .rounded)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: min(1, max(0, 1 - left / Party.nextDelay))).tint(Theme.accent).accessibilityHidden(true)
                Text(left > 0.5 ? "Starts in \(Int(left.rounded(.up))) s" : "Starting…")
                    .font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 10) {
                    Button(action: cancel) { Text("Cancel").frame(width: 100, height: 36) }
                        .buttonStyle(SoftButtonStyle())
                        .accessibilityHint("Stays on this film; the next one does not start by itself")
                    if isHost {
                        Button(action: playNow) { Text("Play now").fontWeight(.semibold).frame(width: 110, height: 36) }
                            .buttonStyle(AccentButtonStyle())
                    }
                }
            }
            .padding(20)
            .frame(width: 290, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.5)))
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.cardBorder))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Up next: \(card.name)")
        }
    }
}

/// The host's queue: what follows when this film ends.
struct UpNextView: View {
    @ObservedObject var party: Party
    let add: () -> Void

    private func line(_ film: QueuedFilm, first: Bool) -> String {
        switch film.state {
        case .waiting: return first ? "Waiting its turn to be got ready" : "Waiting"
        case .preparing(let fraction): return fraction > 0.01 ? "Getting it ready… \(Int(fraction * 100))%" : "Getting it ready…"
        case .ready:
            guard first else { return "Ready" }
            if let fetched = party.nextFetched {
                return fetched >= 1 ? "Ready, and already on your partner's Mac" : "Ready · \(Int(fetched * 100))% already sent to your partner"
            }
            return "Ready"
        case .failed(let reason): return "Can't be used: \(reason)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Up next").font(.headline)
            if party.queue.isEmpty {
                Text("Nothing is queued. Add the next film or episode and it follows by itself when this one ends: it is got ready and sent to your partner in the background while you watch.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(party.queue.enumerated()), id: \.element.id) { index, film in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(film.name).lineLimit(1)
                            Text(line(film, first: index == 0)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button { party.removeFromQueue(film.id) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from the queue")
                        .accessibilityLabel("Remove \(film.name) from the queue")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            HStack(spacing: 10) {
                Button("Add a film…", action: add)
                    .disabled(party.queue.count >= Party.maxQueue)
                    .accessibilityHint("Chooses one or several films that follow this one")
                Spacer()
                Button("Play next now") { party.playNext() }
                    .disabled(party.queue.isEmpty || !party.canChangeFilm)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 400, alignment: .leading)
    }
}

/// A labelled button on the film or on the dark window: a soft pill.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.4))
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.28 : (hovering && enabled ? 0.22 : 0.13))))
            .overlay(Capsule().stroke(.white.opacity(0.1)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

struct ToggleButton: View {
    let on: Bool
    let onIcon: String
    let offIcon: String
    let help: String
    var size: CGFloat = 38
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: on ? onIcon : offIcon)
                .font(.system(size: size * 0.42))
                .frame(width: size, height: size)
                .foregroundStyle(on ? .white : Color.black.opacity(0.85))
                .background(Circle().fill(on ? Color.white.opacity(0.12) : Color.white.opacity(0.85)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The room code while the host is already watching: small, out of the picture, one click to copy.
struct CodeChip: View {
    let code: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            copied = true
        } label: {
            HStack(spacing: 8) {
                Text("Code").foregroundStyle(.white.opacity(0.6))
                Text(RoomCode.pretty(code)).font(.system(size: 14, weight: .semibold, design: .rounded).monospaced())
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.45)))
            .overlay(Capsule().stroke(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Your room code. Click to copy it for your partner.")
        .accessibilityLabel("Room code \(RoomCode.pretty(code)). Copy.")
    }
}

/// What is being played and what happens to it on the way: for the curious, behind the info button.
struct QualityView: View {
    @ObservedObject var party: Party
    @ObservedObject var playback: PlaybackController

    private func origin(_ converted: Bool?) -> String {
        switch converted {
        case .some(false): return "Original stream, not re-encoded"
        case .some(true): return party.role == .host ? "Converted on this Mac so both of you can play it" : "Converted on your partner's Mac so both of you can play it"
        case nil: return party.role == .guest ? "As sent by your partner (their SameSofa is older and doesn't say more)" : ""
        }
    }

    @AppStorage("displayMatch") private var displayMatch = "automatic"
    @ObservedObject private var displayMatcher = DisplayMatcher.shared

    private var displayLine: (String, String, String?) {
        let line = displayMatcher.readout(filmFrameRate: playback.frameRate, settingOn: displayMatch != "off")
        return (line.title, line.detail, line.note)
    }

    var body: some View {
        let hub = party.hub
        let display = displayLine
        VStack(alignment: .leading, spacing: 14) {
            Text("Playback quality").font(.headline)
            if playback.isLoaded {
                row("Picture", playback.quality.video ?? "This film has no picture", playback.quality.video == nil ? "" : origin(party.sharedFilm?.videoConverted))
                row("Sound", playback.quality.audio ?? "This film has no sound", playback.quality.audio == nil ? "" : origin(party.sharedFilm?.audioConverted))
            } else {
                row("Film", "Not loaded yet", party.role == .host ? "The details appear as soon as the film is ready on this Mac."
                    : "The details appear as soon as the first part of the film has arrived.")
            }
            row("Film sound path", playback.systemSpatialAudio ? "Straight to the sound output, with the system's spatial audio" : "Straight to the sound output, no processing",
                "The film is never routed through the call or the microphone clean-up.")
            if hub.mode == .live {
                row("Output", "\(hub.outputRoute.name) (\(hub.outputRoute.kind == .headphones ? "headphones" : "speakers"))", "")
                if party.phase == .together, let trouble = Self.microphoneTrouble(hub) {
                    row("Microphone", trouble.0, trouble.1)
                } else {
                    row("Microphone", party.phase != .together ? "Not in use (no call)"
                            : !party.micOn ? "Muted"
                            : hub.cancelsFilmEcho ? "Echo cancellation removes the film and your partner's voice"
                            : "Echo cancellation removes your partner's voice",
                        party.phase == .together && party.micOn && !hub.cancelsFilmEcho
                            ? (playback.systemSpatialAudio ? "With the system's spatial audio the film can't be removed from the microphone: use headphones."
                               : "Headphones: the microphone doesn't hear the film.") : "")
                }
            }
            row("Display", display.0, display.1)
            if let note = display.2 {
                // A switch of the display was tried and undone: said in one line, where it can be seen.
                Label(note, systemImage: "arrow.uturn.backward.circle")
                    .font(.caption).foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(note)
            }
        }
        .padding(18)
        .frame(width: 430, alignment: .leading)
    }

    /// Why your partner can't hear you, and what to do about it (nil: the microphone works).
    static func microphoneTrouble(_ hub: AudioHub) -> (String, String)? {
        if let error = hub.engineError {
            return ("The call's sound is restarting", "SameSofa keeps trying by itself (\(error)). If it stays like this, check the sound output in System Settings ▸ Sound.")
        }
        switch hub.microphoneState {
        case .working, .notStarted:
            return nil
        case .noDevice:
            return ("No microphone found", "Your partner can't hear you. Connect a microphone or headset; SameSofa picks it up within a couple of seconds.")
        case .accessDenied:
            return ("macOS isn't letting SameSofa use the microphone", "Your partner can't hear you. Allow it in System Settings ▸ Privacy & Security ▸ Microphone, then leave and join again.")
        case .unusable(let reason):
            return ("This microphone can't be used", "Your partner can't hear you (\(reason)). Choose another microphone in System Settings ▸ Sound ▸ Input, or unplug this one and plug it back in.")
        }
    }

    private func row(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            Text(value).font(.callout.monospacedDigit()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        // One row, one thing to hear: "Picture: H.264 ...".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)" + (detail.isEmpty ? "" : ". \(detail)"))
        .accessibilityAddTraits(.isStaticText)
    }
}

struct VolumeControl: View {
    let icon: String
    @Binding var value: Float
    let help: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.white.opacity(0.8)).frame(width: 20).accessibilityHidden(true)
            Slider(value: $value, in: 0...1).frame(width: 84).tint(Theme.accent).controlSize(.small)
                .accessibilityLabel(help)
                .accessibilityValue("\(Int((value * 100).rounded())) percent")
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
    /// The parts of the film the guest has (0...1), drawn faintly on both
    /// sides while the film is still arriving: after a jump ahead it shows
    /// where playing will be immediate and where it has to wait.
    var ranges: [ClosedRange<Double>] = []
    let onScrub: (Double, Bool) -> Void
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
            let height: CGFloat = hovering ? 7 : 5
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(height: height)
                    if ranges.isEmpty {
                        Capsule().fill(Color.white.opacity(0.18)).frame(width: geo.size.width * available, height: height)
                        Capsule().fill(Theme.accent).frame(width: max(0, geo.size.width * fraction), height: height)
                    } else {
                        // What has arrived: clearly brighter than what has not.
                        ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
                            Rectangle().fill(Color.white.opacity(0.4))
                                .frame(width: max(2, geo.size.width * (range.upperBound - range.lowerBound)), height: height)
                                .offset(x: geo.size.width * range.lowerBound)
                        }
                        // Up to the playhead: full colour where the film is here, faint where it is
                        // not (going back there means waiting for it).
                        Rectangle().fill(Theme.accent.opacity(0.38)).frame(width: max(0, geo.size.width * fraction), height: height)
                        ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
                            let end = min(range.upperBound, fraction)
                            if end > range.lowerBound {
                                Rectangle().fill(Theme.accent)
                                    .frame(width: max(1, geo.size.width * (end - range.lowerBound)), height: height)
                                    .offset(x: geo.size.width * range.lowerBound)
                            }
                        }
                    }
                }
                .frame(height: height)
                .clipShape(Capsule())
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
