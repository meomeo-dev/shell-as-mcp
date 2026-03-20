#!/usr/bin/env bash
set -euo pipefail

reencode_audio="${REENCODE_AUDIO:-false}"
audio_delay_ms="${AUDIO_DELAY_MS:-0}"

delay_sec="$(node -e "console.log((Number(process.env.AUDIO_DELAY_MS || 0) / 1000).toFixed(3))")"

if [ "$audio_delay_ms" != "0" ]; then
  cmd=(ffmpeg -hide_banner -loglevel error -y
    -i "$VIDEO_PATH"
    -itsoffset "$delay_sec" -i "$AUDIO_PATH"
    -map 0:v -map 1:a)
else
  cmd=(ffmpeg -hide_banner -loglevel error -y
    -i "$VIDEO_PATH" -i "$AUDIO_PATH"
    -map 0:v -map 1:a)
fi

if [ "$reencode_audio" = "true" ]; then
  cmd+=(-c:v copy -c:a aac -b:a 128k)
else
  cmd+=(-c copy)
fi

cmd+=("$OUTPUT_PATH")
"${cmd[@]}"

node -e 'console.log(JSON.stringify({output_path: process.env.OUTPUT_PATH, video_path: process.env.VIDEO_PATH, audio_path: process.env.AUDIO_PATH, audio_delay_ms: Number(process.env.AUDIO_DELAY_MS || 0), reencode_audio: (process.env.REENCODE_AUDIO || "false") === "true"}))'
