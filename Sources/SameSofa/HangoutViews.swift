import AppKit
import SameSofaCore
import SameSofaKit
import SwiftUI

/// The room without a film on screen: your partner fills the window, you are
/// small in the corner. Shown whenever the two are connected and no film is
/// ready to be watched (none chosen, one being chosen, prepared or fetched).
/// Top to bottom: your partner, a line or small card about the film if there
/// is anything to say, the call's few controls. The picture gives way to the
/// card; nothing covers a face.
struct HangoutView: View {
    @ObservedObject var party: Party
    @ObservedObject var playback: PlaybackController
    /// A film has been watched in this room already.
    let hadFilm: Bool
    let chooseFilm: () -> Void
    let closeFilm: () -> Void

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 16) {
                HangoutStage(party: party)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HangoutControls(party: party, playback: playback, hadFilm: hadFilm, chooseFilm: chooseFilm, closeFilm: closeFilm)
            }
            .padding(.top, 84).padding(.bottom, 26).padding(.horizontal, 40)
        }
    }
}

struct HangoutStage: View {
    @ObservedObject var party: Party
    /// Width over height of the partner's picture.
    @State private var shape: CGFloat = 4.0 / 3.0

    var body: some View {
        partner
            .overlay {
                // You, small in the corner of your partner's picture.
                GeometryReader { geo in
                    selfView(width: min(176, max(96, geo.size.width * 0.26)))
                        .padding(min(16, geo.size.width * 0.03))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !party.partnerMicOn {
                    Label("Muted", systemImage: "mic.slash.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(16)
                        .accessibilityLabel("Your partner's microphone is off")
                }
            }
    }

    @ViewBuilder private var partner: some View {
        if party.partnerCameraOn, party.remoteVideoTrack != nil {
            RTCVideoSurface(track: party.remoteVideoTrack, cornerRadius: 26) { size in
                let next = size.width / size.height
                if abs(next - shape) > 0.01 { shape = next }
            }
            .aspectRatio(shape, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .accessibilityLabel("Your partner's camera")
        } else {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(white: 0.11))
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay(
                    VStack(spacing: 12) {
                        Image(systemName: party.remoteVideoTrack == nil ? "person.fill" : "video.slash.fill").font(.system(size: 54))
                        Text(party.remoteVideoTrack == nil ? "Connecting camera…" : "Your partner's camera is off").font(.title3)
                    }
                    .foregroundStyle(.white.opacity(0.5))
                )
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
        }
    }

    @ViewBuilder private func selfView(width: CGFloat) -> some View {
        if party.cameraOn, party.localVideoTrack != nil {
            RTCVideoSurface(track: party.localVideoTrack, cornerRadius: 14, mirrored: true)
                .frame(width: width, height: width * 0.75)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 10)
                .accessibilityLabel("Your own camera")
        }
    }
}

/// What sits at the bottom of the window while no film is on screen: where
/// the film stands (if one is on its way), and the few controls of the call.
struct HangoutControls: View {
    @ObservedObject var party: Party
    @ObservedObject var playback: PlaybackController
    /// A film has been watched in this room already.
    let hadFilm: Bool
    let chooseFilm: () -> Void
    let closeFilm: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            status
            HStack(spacing: 12) {
                ToggleButton(on: party.micOn, onIcon: "mic.fill", offIcon: "mic.slash.fill",
                             help: party.micOn ? "Mute your microphone" : "Unmute", size: 46) { party.micOn.toggle() }
                ToggleButton(on: party.cameraOn, onIcon: "video.fill", offIcon: "video.slash.fill",
                             help: party.cameraOn ? "Turn your camera off" : "Turn your camera on", size: 46) { party.cameraOn.toggle() }
                VolumeControl(icon: "person.wave.2", value: $party.voiceVolume, help: "Your partner's voice")
                    .padding(.horizontal, 6)
                if party.role == .host {
                    Button(action: chooseFilm) {
                        Label("Choose a film", systemImage: "film.stack")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 22).frame(height: 46)
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!party.canChangeFilm)
                    .help("Pick a film on this Mac to watch together, or drop one on the window (⌘O)")
                    .accessibilityHint("Picks a film on this Mac to watch together")
                }
            }
            .padding(10)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(Theme.cardBorder))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 6)
        }
    }

    /// One short line (or a small card) about the film; nothing technical.
    @ViewBuilder private var status: some View {
        if let notice = party.filmNotice {
            HStack(spacing: 12) {
                NoticeView(text: notice)
                Button { party.filmNotice = nil } label: { Text("OK").frame(width: 56, height: 32) }
                    .buttonStyle(SoftButtonStyle())
            }
        } else if party.role == .host {
            if let preparing = party.preparing {
                card { PreparingView(preparing: preparing, cancel: closeFilm) }
            } else if party.choosingFilm || party.sharedFilm != nil {
                card {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(party.choosingFilm ? "Looking at the film…" : "Opening the film…").font(.title3)
                    }
                }
            }
        } else if let preparing = party.preparing {
            card {
                Text("Your partner's Mac is preparing the film").font(.title3)
                ProgressView(value: preparing.fraction).frame(width: 260).tint(Theme.accent)
                Text("\(Int(preparing.fraction * 100))%").font(.callout.monospacedDigit()).foregroundStyle(Theme.secondaryText)
            }
        } else if party.sharedFilm != nil {
            card {
                Text("Getting the film ready").font(.title3)
                ProgressView(value: party.transferFraction).frame(width: 260).tint(Theme.accent)
                if !party.transferLine.isEmpty { Text(party.transferLine).font(.callout).foregroundStyle(Theme.secondaryText) }
            }
        } else if party.choosingFilm {
            card {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(hadFilm ? "Your partner is choosing another film…" : "Your partner is choosing a film…").font(.title3)
                }
            }
        } else {
            Text("Your partner can choose a film whenever you like.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .padding(.horizontal, 26).padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.cardBorder))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 6)
    }
}
