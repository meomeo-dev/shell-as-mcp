#!/usr/bin/env bash
set -euo pipefail

timestamp="${TIMESTAMP:-00:00:01}"
width="${WIDTH:-1280}"
quality="${QUALITY:-2}"

ffmpeg -hide_banner -loglevel error -y \
  -ss "$timestamp" \
  -i "$INPUT_PATH" \
  -vframes 1 \
  -vf "scale=${width}:-2" \
  -q:v "$quality" \
  "$OUTPUT_PATH"

node -e 'console.log(JSON.stringify({output_path: process.env.OUTPUT_PATH, timestamp: process.env.TIMESTAMP || "00:00:01", width: Number(process.env.WIDTH || 1280), quality: Number(process.env.QUALITY || 2)}))'
