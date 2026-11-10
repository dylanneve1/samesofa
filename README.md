# SameSofa

Watch a film together when you are not in the same place. One of you picks a
video file on their Mac, the other types a six-character code, and you both
watch it in sync, with a little floating video call bubble so you can see and
hear each other.

- **Play, pause and seek from either side.** Both players follow one shared
  timeline and correct themselves so they stay within a fraction of a second.
- **Only one of you needs the file.** It is streamed to the other Mac directly
  (peer to peer) at original quality and decoded locally.
- **Video call bubble** over the film: drag it anywhere, make it bigger or
  smaller, hide it. Mute and camera-off buttons. Controls fade away while the
  film plays.
- **No echo** of the film through the other person's microphone: the film, the
  voice and the microphone all go through Apple's voice processing (details
  below), with separate film and voice volume sliders.
- **Private by design**: no accounts, no analytics, nothing stored on a server.

![Joined and ready to play](docs/screenshots/guest-joined.png)

| | |
|---|---|
| ![Welcome](docs/screenshots/welcome.png) | ![Typing the code](docs/screenshots/join.png) |
| ![The host's code](docs/screenshots/host-waiting.png) | ![Playing, controls hidden](docs/screenshots/playing.png) |

*(Screenshots use a generated test film and a generated stand-in camera
picture.)*

---

## Install (for the person who just wants to watch)

1. Open the **SameSofa .dmg** (or .zip) you were sent and drag **SameSofa** into
   **Applications**.
2. Open SameSofa from Applications. The first time, macOS will say it can't
   check the app for malicious software, because SameSofa isn't sold through
   Apple. That's expected:
   - Click **Done** (or **OK**) on that message.
   - Open **System Settings → Privacy & Security**, scroll down, and next to
     *"SameSofa was blocked…"* click **Open Anyway**. Enter your Mac password
     if asked, then click **Open Anyway** once more.
   - On macOS 14 you can instead right-click (or Control-click) SameSofa in
     Applications, choose **Open**, then **Open**.

   You only have to do this once. (For the technical one of you: running
   `xattr -dr com.apple.quarantine /Applications/SameSofa.app` in Terminal
   does the same thing.)
3. When SameSofa asks to use the **camera** and **microphone**, click **Allow**,
   so your partner can see and hear you. (If you clicked *Don't Allow* by
   mistake: System Settings → Privacy & Security → Camera / Microphone → turn
   SameSofa on, then quit and reopen SameSofa.)

### Watching

- **If you're joining:** click **Join** and type the code your partner reads to
  you. That's it. The film appears and starts as soon as enough of it has
  arrived.
- **If you're hosting:** click **Host**, pick the film (or drop it on the
  window), and read the code on screen to your partner.
- Either of you can press **Play together**, pause, or skip. Move the mouse to
  bring the controls back. Double-click the film (or press **F**) for full
  screen. **Space** plays/pauses, **←/→** skip 10 seconds, **M** mutes you.
- Watching on laptop speakers works; headphones give the best film sound (see
  *Settings → Audio*).

---

## What files work

SameSofa plays whatever macOS itself (AVFoundation) can play:

| Works | Doesn't (yet) |
|---|---|
| `.mp4`, `.m4v`, `.mov` with H.264 or HEVC (H.265) video | `.mkv`, `.webm`, `.avi`, `.flv`, `.wmv` containers |
| AAC, ALAC, MP3, AC-3 / E-AC-3 (Dolby Digital) audio | DTS audio, VP9/AV1 inside MKV/WebM |
| Files whose index (`moov`) is at the end are fine | Separate subtitle files (`.srt`) and subtitles inside MKV |

The host is told straight away if a file can't be played.

**MKV today:** most MKV files hold H.264/HEVC + AAC/AC-3 and can be rewrapped
into MP4 in seconds without re-encoding: `ffmpeg -i film.mkv -map 0:v:0 -map 0:a:0 -c copy film.mp4`.

**MKV later, in the app:** the transfer layer already moves arbitrary bytes, so
only the host's player needs to understand MKV. Options, roughly in order of
effort: (1) remux on the host before sharing, using a bundled `ffmpeg`/libavformat
built as LGPL and loaded dynamically (keep it out of the MIT binary, ship its
source/licence); (2) write a small Matroska demuxer in Swift that feeds
`AVSampleBufferDisplayLayer` / `AVSampleBufferAudioRenderer` and keep the same
sync engine; (3) VLCKit (LGPL) as an alternative player for unsupported files.

---

## How it works

```
   Host Mac                                               Guest Mac
 ┌────────────────────────┐                        ┌────────────────────────┐
 │ AVPlayer (local file)  │  control channel: play/pause/seek, heartbeats,  │
 │ SyncEngine ◄───────────┼──── clock ping/pong, chunk requests ──────────►│ SyncEngine
 │ FileSender ────────────┼──── file channel: original bytes (64 KiB) ────►│ FileReceiver → sparse temp file
 │                        │                                                 │   → AVAssetResourceLoader → AVPlayer
 │ AudioHub (AVAudioEngine│◄─── WebRTC audio + video (camera, mic) ───────►│ AudioHub
 │  + voice processing)   │        all peer to peer, DTLS/SRTP encrypted    │
 └──────────▲─────────────┘                                                 └──────────▲─────────────┘
            │  WebSocket: "create room" / "join ABC123" / relay offer, answer, ICE        │
            └──────────────────────► server/ (tiny Node room server) ◄──────────────────┘
```

### Getting the film to the guest: the original bytes, over a data channel

The host does **not** re-encode the film into a live video stream. It sends the
**original file** over a reliable, ordered WebRTC data channel, in 64 KiB chunks,
and the guest plays it from a local sparse file through
`AVAssetResourceLoaderDelegate` (a custom `samesofa-film://` URL). So:

- picture and sound are the original quality, and each Mac decodes locally,
  which is also what makes frame-accurate sync possible;
- the guest asks for chunks (a window of 64 in flight). Ranges the player is
  waiting for jump the queue on both sides; next come the last chunks of the
  file (MP4 files often keep their index at the end, so this makes them
  startable quickly), then everything from the playhead forwards, then the rest;
- the host never lets more than ~2 MB queue up inside WebRTC
  (`bufferedAmount` backpressure) so a seek redirects the transfer quickly;
- playback starts once about 8 seconds ahead are available. If the guest runs
  dry, **both** sides pause ("Waiting for your partner to catch up…") and the
  host restarts both together when the guest is ready again;
- the whole file keeps arriving in the background and is checked byte for byte
  in the integration test. The guest's copy lives in a temporary folder and is
  deleted when the session ends (and at the start of the next one, in case the
  app was force-quit).

Re-encoding into a WebRTC video track would have been simpler to start but
loses quality, costs CPU on the host for the whole film, and makes the call and
the film fight over one congestion controller. It was not needed.

### Staying in sync

Both apps run the same `SyncEngine` (in `Sources/SameSofaCore`, unit tested):

- A **shared timeline** says "the film is at position *p* at shared time *t*,
  playing or paused". Any button press on either side creates a new timeline
  with a higher sequence number; simultaneous presses resolve the same way on
  both sides (higher sequence wins, host breaks ties).
- The guest measures the **clock offset** to the host NTP-style (ping/pong on the
  control channel, minimum-round-trip sample wins).
- Play is scheduled ~0.35 s in the future and started with
  `AVPlayer.setRate(_:time:atHostTime:)` so both start on the same instant.
- Every half second each side compares its player with the timeline: gaps under
  60 ms are ignored; up to 1 s the playback speed is nudged by up to ±4% (pitch
  preserved) until it catches up; beyond that it seeks.
- The host sends a heartbeat every second so a missed message is healed.

### Echo cancellation: the approach and its limits

The problem: both Macs play the film out loud. The guest's microphone hears the
guest's film and the host's voice, and without care the host would hear their
own voice and a second, delayed copy of the film.

WebRTC has an echo canceller (AEC3), but on macOS WebRTC opens the speakers and
microphone itself and only knows about the audio *it* plays (the other person's
voice). Audio played by AVPlayer is invisible to it, so it cannot remove the
film. An echo canceller can only remove what it has as a **reference**.

So SameSofa routes everything through **one audio engine**:

- `AudioHub` is a custom WebRTC audio device (WebRTC's `RTCAudioDevice` protocol;
  the macOS framework implements it but doesn't ship the header, so it is
  re-declared in `Sources/CWebRTCAudioDevice`). WebRTC hands it the remote voice
  to play and receives the microphone from it.
- It runs an `AVAudioEngine` with **Apple's voice processing** enabled on the
  input node (`setVoiceProcessingEnabled(true)`, the same echo cancellation and
  noise suppression FaceTime uses).
- The film's decoded audio is taken out of AVPlayer with an
  `MTAudioProcessingTap`, AVPlayer's own output is silenced, and the film is
  played through the same engine. The other person's voice is played there too.
- Because the voice-processing unit plays both, both are its echo reference and
  are removed from the microphone before WebRTC sends it. SameSofa also asks
  WebRTC to switch its own echo cancellation and gain control off, so two
  cancellers don't fight (whether WebRTC M157 still honours these legacy
  constraints hasn't been verified; if it doesn't, its canceller simply finds
  little left to remove).
- The film and voice volume sliders are mixer volumes in that engine.

Limits, honestly:

- This could only be tested on a Mac with **no microphone** (the build machine),
  where voice processing cannot start; there the app falls back automatically
  and shows "Echo cancellation isn't available on this Mac. Headphones
  recommended." Real echo-cancellation quality with speakers and a laptop mic
  has not been measured yet.
- Voice processing is tuned for speech. Loud film audio at high volume through
  laptop speakers is the hardest case: expect some residual film or ducking of
  your voice in very loud scenes. If that's annoying, use headphones.
- With voice processing on, macOS may play the film in a slightly reduced
  quality mode (it is a "voice chat" audio path). **Settings → Audio →
  Headphones** turns voice processing off for full-quality film sound; then
  headphones are needed to avoid echo.
- The film's sound goes through a small buffer (~50 ms or less) on its way to
  the engine, so it can lag the picture by a few tens of milliseconds.
- Surround tracks are mixed down to stereo (dialogue kept in the middle).

### The room server

`server/` is ~150 lines of Node with one dependency (`ws`). It:

- creates a room with a random 6-character code (no `0/O/1/I/L`, so codes
  survive being read out), lets exactly one guest join, and relays WebRTC
  offers, answers and ICE candidates between the two;
- never sees audio, video or the film; keeps rooms only in memory; rooms expire
  after 12 hours; a guest can rejoin a room if they drop;
- closes a connection after 10 wrong codes, caps message size at 64 KB;
- logs only "room created/joined" lines with a timestamp (no codes, no IPs).

Once the two Macs are connected, the room server is no longer needed for that
session.

---

## Privacy

- Camera, microphone and the film go **directly between the two Macs** over
  WebRTC, encrypted with DTLS-SRTP (media) and DTLS (data channels). There is no
  SameSofa cloud.
- The **room server** you run sees: the room code, the two IP addresses that
  connect to it, and the WebRTC connection descriptions it relays (which include
  your network addresses). It keeps none of this beyond the open room in memory.
- **STUN** servers (by default Google's and Cloudflare's public ones) see your
  public IP address so your Mac can learn it. If you configure a **TURN** relay,
  that relay carries your encrypted traffic but cannot decrypt it.
- No accounts, no analytics, no crash reporting, nothing written anywhere except
  the guest's temporary copy of the film (deleted after the session) and your
  settings in the app's preferences.

---

## Run the room server

Both apps must use the same server, reachable over `wss://` (TLS) from the
internet. The server listens on plain HTTP/WebSocket; put it behind any
TLS-terminating reverse proxy.

**Docker**

```sh
cd server
docker build -t samesofa-signalling .
docker run -d --name samesofa --restart unless-stopped -p 127.0.0.1:8787:8787 samesofa-signalling
```

**systemd** (no Docker): see `server/samesofa-signalling.service` for a hardened
example unit; it expects the folder at `/opt/samesofa-signalling` and Node 18+.

**Reverse proxy**, e.g. Caddy (handles certificates and WebSockets automatically):

```
sofa.example.org {
    reverse_proxy 127.0.0.1:8787
}
```

nginx needs the usual WebSocket upgrade headers (`proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade";`)
and a `proxy_read_timeout` above the server's 25-second ping interval.

Check it: `curl https://sofa.example.org/` should print `samesofa signalling ok`.

Environment variables: `PORT` (default 8787), `HOST` (default `127.0.0.1`; the
Docker image uses `0.0.0.0`).

### Point the app at it

Either:

- **Bake it in** (best for the non-technical side; nothing to type):
  `SAMESOFA_SERVER_URL=wss://sofa.example.org scripts/build.sh`, then send that
  build; or
- **Settings**: SameSofa ▸ Settings… ▸ *Server address*, on both Macs. Settings
  survive app updates.

Builds without a server show a friendly "this copy doesn't know its server yet"
message instead of trying `wss://CHANGE-ME.example`.

### When you need TURN

Most home connections work with STUN alone. Some networks (symmetric NAT,
carrier-grade NAT on mobile, strict office/hotel/university Wi-Fi) need a TURN
relay: run e.g. [coturn](https://github.com/coturn/coturn) and enter its
`turn:` / `turns:` URL, username and password under *Settings ▸ Advanced
networking* on both Macs.

---

## Build from source

Requirements: macOS 14+, Xcode 16 or newer (Swift 5.10+). Node 18+ for the
server.

```sh
scripts/build.sh            # universal (Apple silicon + Intel) app, .zip and .dmg in dist/
SAMESOFA_ARCHS=arm64 scripts/build.sh                     # faster, Apple silicon only
SAMESOFA_SERVER_URL=wss://sofa.example.org scripts/build.sh   # bake in your server
```

`scripts/build.sh` downloads WebRTC (checksum verified) into `Vendor/`, builds
with SwiftPM, assembles `build/SameSofa.app` (Info.plist with camera and
microphone usage strings, WebRTC.framework embedded) and signs it:

- with `SAMESOFA_SIGN_IDENTITY="Developer ID Application: …"` it signs with the
  hardened runtime and `Resources/SameSofa.entitlements` (camera, audio input).
  It does not notarize; do that yourself with `xcrun notarytool` if you have an
  Apple Developer account, which removes the "Open Anyway" step;
- otherwise it **ad-hoc** signs (fine for personal use, needs the Gatekeeper
  step above).

### Tests

```sh
swift test                          # sync engine, clock sync, chunk scheduling, byte-exact reassembly
(cd server && npm ci && npm test)   # room server
```

End-to-end test: two complete peers (host and guest) in one process, real
WebRTC, real AVPlayers, a real room server over loopback, synthetic camera and
microphone, no sound played:

```sh
(cd server && PORT=18787 node server.js &)
ffmpeg -f lavfi -i testsrc2=s=1280x720:r=24:d=180 -f lavfi -i sine=f=330:d=180 \
       -c:v libx264 -b:v 1500k -pix_fmt yuv420p -c:a aac test.mp4     # moov at the end
swift build --product samesofa-itest
.build/debug/samesofa-itest --server ws://127.0.0.1:18787 --film test.mp4 --soak 120
.build/debug/samesofa-itest --server ws://127.0.0.1:18787 --film test.mp4 --soak 90 --throttle 150000
```

It checks: room by code (typed in lower case with a dash), video and audio both
ways, guest playback without having the file, clock-offset discovery (the guest
pretends its clock is 1234.567 s off), play/pause/seek from both sides, recovery
from a forced 0.7 s and 4 s drift, drift under 0.25 s for the soak period, the
received file being byte-identical (SHA-256), and leaving/rejoining. The
`--throttle` run caps the host's upload below the film's bitrate and checks that
both sides pause when the guest runs dry and resume together.

`.github/workflows/ci.yml` runs the server tests, the unit tests and an
Apple-silicon app build on GitHub's macOS runners. It is manual-only for now
(see the comment in the file); switch it to run on push once the repository is
public.

`.build/debug/samesofa-itest --audio-check` starts the real voice-processing
audio engine at zero volume and reports whether it runs on that Mac.

### Layout

```
Sources/SameSofaCore      protocol messages, sync engine, clock sync, chunk map/scheduler (pure Swift, unit tested)
Sources/SameSofaKit       WebRTC call, data channels, file sender/receiver, playback controller, audio engine
Sources/SameSofa          the SwiftUI app
Sources/samesofa-itest    end-to-end test runner
Sources/CWebRTCAudioDevice, CAudioTap   small C/Objective-C headers and shims
server/                   room server (Node + ws), tests, Dockerfile, systemd unit
scripts/                  build.sh, fetch-webrtc.sh, make-icon.swift
```

---

## Known limits and what hasn't been tested

- Tested on one Mac over loopback only: real NAT traversal between two homes in
  different countries, slow or lossy uplinks, and long (2-hour, multi-GB) films
  have not been exercised end to end. The throttled test simulates a slow
  uplink; real networks will add jitter.
- Echo cancellation with real speakers and microphones is untested (see above).
- The real camera path (`RTCCameraVideoCapturer`) is untested here (no camera on
  the build machine); tests and screenshots use a synthetic camera.
- The film transfer and the video call share the host's upload. On a slow
  uplink the call video is capped at 700 kbit/s, but a large file transfer can
  still make the call choppier until the guest has enough buffered.
- If the connection between the two drops (Wi-Fi change, sleep), the host goes
  back to "waiting" with the same code and the guest has to rejoin; the guest
  re-downloads the film into a new temporary file.
- The guest needs free disk space roughly the size of the film.
- One film per session; to switch films, leave and host again.

---

## Third-party software

| Component | Licence | Used for |
|---|---|---|
| [WebRTC](https://webrtc.org) M157, prebuilt by [stasel/WebRTC](https://github.com/stasel/WebRTC) | BSD-3-Clause (+ WebRTC patent grant) | calls, data channels (embedded `WebRTC.framework`) |
| `RTCAudioDevice.h` copied from WebRTC | BSD-3-Clause | custom audio device protocol |
| [ws](https://github.com/websockets/ws) | MIT | room server WebSocket |
| Apple SF Symbols | Apple's terms, via the system | icons in the app |

No GPL or LGPL code is linked into the app.

## Licence

MIT, see [LICENSE](LICENSE).
