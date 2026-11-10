# Third-party notices

SameSofa's own code is licensed under MIT-0 (see LICENSE). It uses the
third-party software below, which keeps its own licence. This file is
copied into the app (SameSofa ▸ Acknowledgements…, and
`SameSofa.app/Contents/Resources/THIRD-PARTY-NOTICES.md`).

| Component | Licence | Where | Used for |
|---|---|---|---|
| [WebRTC](https://webrtc.org) M157, prebuilt by [stasel/WebRTC](https://github.com/stasel/WebRTC) | BSD-3-Clause + WebRTC patent grant | `WebRTC.framework` inside the app | calls, data channels |
| `RTCAudioDevice.h` from WebRTC | BSD-3-Clause | `Sources/CWebRTCAudioDevice` | custom audio device protocol |
| [FFmpeg](https://ffmpeg.org) 8.1.3 | LGPL-2.1-or-later | `ffmpeg`, `ffprobe` in `Contents/Helpers`, `libav*.dylib`/`libsw*.dylib` in `Contents/Frameworks` | converting MKV, AVI, WebM, ... to MP4 on the host |
| [dav1d](https://code.videolan.org/videolan/dav1d) 1.5.4 | BSD-2-Clause | linked statically into `libavcodec.62.dylib` | decoding AV1 video during conversion |
| [ws](https://github.com/websockets/ws) | MIT | room server only (installed by npm, not part of the app) | WebSocket server |
| Apple SF Symbols | Apple's terms, via the system | the system | icons in the app |

---

## WebRTC

Used unmodified as a prebuilt framework (`WebRTC.framework`). The header
`Sources/CWebRTCAudioDevice/include/RTCAudioDevice.h` is copied from the
WebRTC sources and keeps its original copyright header.

```
Copyright (c) 2011, The WebRTC project authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### WebRTC: additional IP rights grant (patents)

```
Additional IP Rights Grant (Patents)

"This implementation" means the copyrightable works distributed by
Google as part of the WebRTC code package.

Google hereby grants to you a perpetual, worldwide, non-exclusive,
no-charge, irrevocable (except as stated in this section) patent
license to make, have made, use, offer to sell, sell, import,
transfer, and otherwise run, modify and propagate the contents of this
implementation of the WebRTC code package, where such license applies
only to those patent claims, both currently owned by Google and
acquired in the future, licensable by Google that are necessarily
infringed by this implementation of the WebRTC code package. This
grant does not include claims that would be infringed only as a
consequence of further modification of this implementation. If you or
your agent or exclusive licensee institute or order or agree to the
institution of patent litigation against any entity (including a
cross-claim or counterclaim in a lawsuit) alleging that this
implementation of the WebRTC code package or any code incorporated
within this implementation of the WebRTC code package constitutes
direct or contributory patent infringement, or inducement of patent
infringement, then any patent rights granted to you under this License
for this implementation of the WebRTC code package shall terminate as
of the date such litigation is filed.
```

---

## FFmpeg

SameSofa's host side converts films macOS can't open (MKV, AVI, WebM, ...) to
MP4 with FFmpeg. FFmpeg is licensed under the GNU Lesser General Public License
version 2.1 or later (LGPL-2.1-or-later). Its full text is in
`SameSofa.app/Contents/Resources/FFmpeg/COPYING.LGPLv2.1` (copied unchanged
from the FFmpeg sources) and at https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.

- **Version:** FFmpeg 8.1.3, unmodified.
- **Corresponding source:** https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz
  (SHA-256 `7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3`,
  signed by the FFmpeg release key). SameSofa applies no patches.
- **How it was built:** `scripts/build-ffmpeg.sh` in SameSofa's source code,
  which downloads exactly that tarball, checks its SHA-256 and configures it
  with these options (per architecture, arm64 and x86_64, then merged):

  ```
  --disable-gpl --disable-nonfree --disable-version3 --enable-libdav1d
  --enable-shared --disable-static --install-name-dir=@rpath
  --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib
  --disable-doc --disable-ffplay --disable-avdevice --disable-network --disable-devices --disable-debug
  --disable-encoders --enable-encoder=aac,alac,h264_videotoolbox,hevc_videotoolbox,movtext
  --disable-muxers --enable-muxer=mp4,mov,null,srt,webvtt
  --disable-filters --enable-filter=scale,format,aformat,aresample,null,anull,copy,acopy,setpts,asetpts,fps,pan,yadif
  --disable-protocols --enable-protocol=file,pipe
  ```

  No GPL or nonfree parts and no x264/x265: video is encoded with Apple's
  VideoToolbox, audio with FFmpeg's own AAC encoder. The only external
  library is dav1d (AV1 decoder, BSD-2-Clause, see below), built by the same
  script from https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz
  (SHA-256 `686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5`). The exact configuration of a build is in
  `Contents/Resources/FFmpeg/BUILDINFO.txt` (`ffmpeg -buildconf`).
- **Separate and replaceable:** FFmpeg is not linked into SameSofa. The app runs
  `Contents/Helpers/ffmpeg` and `ffprobe` as separate programs, which load
  the FFmpeg shared libraries from `Contents/Frameworks`. You may replace them
  with your own build of FFmpeg (for example a modified one built with
  `scripts/build-ffmpeg.sh`): copy the programs and libraries into the same
  places and re-sign the app (`codesign --force --deep --sign - SameSofa.app`).

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.

### dav1d

Linked statically into the FFmpeg helper's `libavcodec` (unmodified, version
1.5.4). Licence (also in `Contents/Resources/FFmpeg/COPYING.dav1d`):

```
Copyright © 2018-2025, VideoLAN and dav1d authors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.```

---

## ws

The room server (`server/`, not part of the Mac app) depends on
[ws](https://github.com/websockets/ws), MIT licence. npm installs ws together
with its licence file (`server/node_modules/ws/LICENSE`).
