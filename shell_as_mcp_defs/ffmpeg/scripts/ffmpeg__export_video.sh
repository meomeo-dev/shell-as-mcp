#!/usr/bin/env bash
set -euo pipefail

video_codec="${VIDEO_CODEC:-libx264}"
preset="${PRESET:-medium}"
pixel_format="${PIXEL_FORMAT:-yuv420p}"
audio_bitrate="${AUDIO_BITRATE:-128k}"

cmd=(ffmpeg -hide_banner -loglevel error -y -i "$INPUT_PATH"
  -c:v "$video_codec"
  -pix_fmt "$pixel_format"
  -c:a aac -b:a "$audio_bitrate")

if [ -n "${PRESET:-}" ] && [ "$video_codec" != "libvpx-vp9" ]; then
  cmd+=(-preset "$preset")
fi

if [ -n "${BITRATE:-}" ]; then
  cmd+=(-b:v "$BITRATE")
elif [ "$video_codec" = "libvpx-vp9" ]; then
  cmd+=(-b:v 0 -crf "${CRF:-33}")
else
  cmd+=(-crf "${CRF:-23}")
fi

if [ -n "${PROFILE:-}" ]; then
  cmd+=(-profile:v "$PROFILE")
fi

if [ -n "${LEVEL:-}" ]; then
  cmd+=(-level:v "$LEVEL")
fi

if [ -n "${RESOLUTION:-}" ]; then
  res_w="${RESOLUTION%%x*}"
  res_h="${RESOLUTION##*x}"
  cmd+=(-vf "scale=${res_w}:${res_h}")
fi

cmd+=("$OUTPUT_PATH")
"${cmd[@]}"

node -e 'console.log(JSON.stringify({output_path: process.env.OUTPUT_PATH, video_codec: process.env.VIDEO_CODEC || "libx264", crf: process.env.CRF ? Number(process.env.CRF) : null, bitrate: process.env.BITRATE || null, preset: process.env.PRESET || "medium", profile: process.env.PROFILE || null, level: process.env.LEVEL || null, resolution: process.env.RESOLUTION || null, audio_bitrate: process.env.AUDIO_BITRATE || "128k", pixel_format: process.env.PIXEL_FORMAT || "yuv420p"}))'
