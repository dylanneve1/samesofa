# Third-party notices

SameSofa's own code is licensed under MIT-0 (see LICENSE). It uses the
third-party software below, which keeps its own licence. This file is
copied into the app (SameSofa ▸ Acknowledgements…, and
`SameSofa.app/Contents/Resources/THIRD-PARTY-NOTICES.md`).

| Component | Licence | Where | Used for |
|---|---|---|---|
| [WebRTC](https://webrtc.org) M157, prebuilt by [stasel/WebRTC](https://github.com/stasel/WebRTC) | BSD-3-Clause + WebRTC patent grant | `WebRTC.framework` inside the app | calls, data channels |
| `RTCAudioDevice.h` from WebRTC | BSD-3-Clause | `Sources/CWebRTCAudioDevice` | custom audio device protocol |
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

## ws

The room server (`server/`, not part of the Mac app) depends on
[ws](https://github.com/websockets/ws), MIT licence. npm installs ws together
with its licence file (`server/node_modules/ws/LICENSE`).
