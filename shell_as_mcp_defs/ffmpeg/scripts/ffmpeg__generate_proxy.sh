#!/usr/bin/env bash
set -euo pipefail

proxy_width="${WIDTH:-1280}"
crf="${CRF:-28}"
pixel_format="${PIXEL_FORMAT:-yuv420p}"

vf_filter="scale=${proxy_width}:-2"

cmd=(ffmpeg -hide_banner -loglevel error -y
  -i "$INPUT_PATH"
  -c:v libx264 -preset veryfast -crf "$crf"
  -pix_fmt "$pixel_format"
  -vf "$vf_filter"
  -c:a aac -b:a 96k)

if [ -n "${FPS:-}" ]; then
  cmd+=(-r "$FPS")
fi

cmd+=("$OUTPUT_PATH")
"${cmd[@]}"

node -e 'console.log(JSON.stringify({output_path: process.env.OUTPUT_PATH, width: Number(process.env.WIDTH || 1280), crf: Number(process.env.CRF || 28), fps: process.env.FPS ? Number(process.env.FPS) : null, pixel_format: process.env.PIXEL_FORMAT || "yuv420p"}))'
