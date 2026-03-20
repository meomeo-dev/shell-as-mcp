#!/usr/bin/env bash
set -euo pipefail

target_lufs="${TARGET_LUFS:--14}"
true_peak="${TRUE_PEAK:--1.0}"
lra="${LOUDNESS_RANGE:-11}"

ffmpeg -hide_banner -loglevel error -y \
  -i "$INPUT_PATH" \
  -af "loudnorm=I=${target_lufs}:TP=${true_peak}:LRA=${lra}" \
  "$OUTPUT_PATH"

node -e 'console.log(JSON.stringify({output_path: process.env.OUTPUT_PATH, target_lufs: Number(process.env.TARGET_LUFS || -14), true_peak: Number(process.env.TRUE_PEAK || -1.0), loudness_range: Number(process.env.LOUDNESS_RANGE || 11)}))'
