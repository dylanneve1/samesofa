#!/bin/sh
# Generates the synthetic test films for the conversion tests (no real media).
# Every clip has a white flash and a 1 kHz beep at t = 1, 4, 7, ... s over a
# quiet 330 Hz tone, so audio/video sync can be measured after conversion.
#
# Needs a full FFmpeg with libx264, libx265, libvpx, libopus and libmp3lame
# (e.g. Homebrew's). That FFmpeg is only used to make test files; it is not
# the LGPL helper that ships with the app.
#
#   scripts/dev/make-test-films.sh <out-dir> [seconds]
#   scripts/dev/make-test-films.sh <out-dir> long     # 10-minute 1080p clips for speed tests
set -eu
OUT=${1:?usage: make-test-films.sh <out-dir> [seconds|long]}
D=${2:-40}
FF=${FFMPEG:-ffmpeg}
mkdir -p "$OUT"
cd "$OUT"

video() { # size rate seconds
  echo "testsrc2=s=$1:r=$2:d=$3,drawbox=c=white:t=fill:enable='lt(mod(t+2\,3)\,0.04)'"
}
audio() { # seconds [base tone Hz]
  echo "aevalsrc='if(lt(mod(t+2\,3)\,0.1)\,0.8*sin(2*PI*1000*t)\,0.05*sin(2*PI*${2:-330}*t))':s=48000:d=$1"
}
q() { "$FF" -hide_banner -loglevel error -y "$@"; }

if [ "$D" = long ]; then
  L=600
  # Remux path: 1080p H.264 + AAC in MKV, ~8 Mbit/s.
  q -f lavfi -i "$(video 1920x1080 24 $L)" -f lavfi -i "$(audio $L)" \
    -c:v libx264 -preset veryfast -b:v 8M -pix_fmt yuv420p -c:a aac -b:a 192k long-h264-aac.mkv
  # Transcode path: 1080p MPEG-4 ASP (Xvid-style) + MP3 in AVI.
  q -f lavfi -i "$(video 1920x1080 24 $L)" -f lavfi -i "$(audio $L)" \
    -c:v mpeg4 -vtag XVID -q:v 4 -bf 2 -c:a libmp3lame -b:a 192k long-xvid-mp3.avi
  # Transcode path: 1080p VP9 + Opus in WebM.
  q -f lavfi -i "$(video 1920x1080 24 $L)" -f lavfi -i "$(audio $L)" \
    -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 -b:v 6M -c:a libopus -b:a 160k long-vp9-opus.webm
  ls -la
  exit 0
fi

# MKV, H.264 + AAC: remux only.
q -f lavfi -i "$(video 1280x720 24 $D)" -f lavfi -i "$(audio $D)" \
  -c:v libx264 -preset veryfast -b:v 2M -pix_fmt yuv420p -c:a aac -b:a 160k h264-aac.mkv
# MKV, HEVC 10-bit + AC-3 5.1: remux only (tagged hvc1).
q -f lavfi -i "$(video 1280x720 24 $D)" -f lavfi -i "$(audio $D)" \
  -c:v libx265 -preset fast -x265-params log-level=error -b:v 2M -pix_fmt yuv420p10le -c:a ac3 -ac 6 -b:a 384k hevc10-ac3.mkv
# MKV, VP9 + Opus: both transcoded.
q -f lavfi -i "$(video 1280x720 30 $D)" -f lavfi -i "$(audio $D)" \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 2M -c:a libopus -b:a 128k vp9-opus.mkv
# AVI, MPEG-4 ASP (Xvid-style, B-frames) + MP3: video transcoded, MP3 copied.
q -f lavfi -i "$(video 720x400 25 $D)" -f lavfi -i "$(audio $D)" \
  -c:v mpeg4 -vtag XVID -q:v 4 -bf 2 -c:a libmp3lame -b:a 160k xvid-mp3.avi
# AVI, H.264 (B-frames, no timestamps in AVI) + MP3, with a same-named .srt next to it.
q -f lavfi -i "$(video 1280x720 24 $D)" -f lavfi -i "$(audio $D)" \
  -c:v libx264 -preset veryfast -b:v 2M -pix_fmt yuv420p -c:a libmp3lame -b:a 160k h264-mp3.avi
cat > subs.srt <<'EOF'
1
00:00:00,500 --> 00:00:03,000
First line of a test subtitle

2
00:00:04,000 --> 00:00:06,500
Second line, after the first beep

3
00:00:10,000 --> 00:00:14,000
Third line
EOF
cp subs.srt h264-mp3.srt
# MKV with two audio tracks (the second is the default, 550 Hz base tone) and an embedded SRT.
q -f lavfi -i "$(video 1280x720 24 $D)" -f lavfi -i "$(audio $D)" -f lavfi -i "$(audio $D 550)" -i subs.srt \
  -map 0:v -map 1:a -map 2:a -map 3:s -c:v libx264 -preset veryfast -b:v 2M -pix_fmt yuv420p \
  -c:a aac -b:a 128k -c:s srt -disposition:a:0 0 -disposition:a:1 default \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=fra -metadata:s:s:0 language=eng two-audio-srt.mkv
rm subs.srt
ls -la
