#!/usr/bin/env bash
set -euo pipefail

voice_vol="${VOICE_VOLUME:-1.0}"
bgm_vol="${BGM_VOLUME:-0.3}"
duration="${DURATION:-shortest}"

ffmpeg -hide_banner -loglevel error -y \
  -i "$VOICE_PATH" \
  -i "$BGM_PATH" \
  -filter_complex \
    "[0:a]volume=${voice_vol}[voice];[1:a]volume=${bgm_vol}[bgm];[voice][bgm]amix=inputs=2:duration=${duration}[out]" \
  -map "[out]" \
  "$OUTPUT_PATH"

node -e 'console.log(JSON.stringify({output_path: process.env.OUTPUT_PATH, voice_volume: Number(process.env.VOICE_VOLUME || 1.0), bgm_volume: Number(process.env.BGM_VOLUME || 0.3), duration: process.env.DURATION || "shortest"}))'
