#!/usr/bin/env bash
set -euo pipefail

reencode="${REENCODE:-false}"
video_codec="${VIDEO_CODEC:-libx264}"
audio_codec="${AUDIO_CODEC:-aac}"

tmp_dir="$(mktemp -d)"
list_file="$tmp_dir/concat_list.txt"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

clip_count=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  printf "file '%s'\n" "$p" >> "$list_file"
  clip_count=$((clip_count + 1))
done < <(printf '%s\n' "$INPUT_PATHS" | tr ',' '\n')

if [ "$clip_count" -eq 0 ]; then
  echo "No valid input paths provided." >&2
  exit 1
fi

cmd=(ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$list_file")

if [ "$reencode" = "true" ]; then
  cmd+=(-c:v "$video_codec" -preset veryfast -crf 23 -c:a "$audio_codec" -b:a 128k)
else
  cmd+=(-c copy)
fi

cmd+=("$OUTPUT_PATH")
"${cmd[@]}"

node -e 'console.log(JSON.stringify({output_path: process.env.OUTPUT_PATH, clip_count: Number(process.argv[1]), reencode: (process.env.REENCODE || "false") === "true", video_codec: process.env.VIDEO_CODEC || "libx264", audio_codec: process.env.AUDIO_CODEC || "aac"}))' "$clip_count"
