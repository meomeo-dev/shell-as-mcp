#!/usr/bin/env bash
set -euo pipefail

interval_sec="${INTERVAL_SEC:-300}"
clip_duration_sec="${CLIP_DURATION_SEC:-2}"
merge_audio="${MERGE_AUDIO:-true}"

tmp_dir="$(mktemp -d)"
list_file="$tmp_dir/concat.txt"
clip_index=0

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

while IFS= read -r input_path; do
  [ -z "$input_path" ] && continue
  duration_raw="$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$input_path" || echo "0")"
  if ! [[ "$duration_raw" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    continue
  fi
  duration_int="$(node -e 'const d=Number(process.argv[1]); console.log(Number.isFinite(d) ? Math.ceil(d) : 0);' "$duration_raw")"
  if [ "$duration_int" -le 0 ]; then
    continue
  fi

  current=0
  while [ "$current" -lt "$duration_int" ]; do
    clip_path="$tmp_dir/clip_$(printf "%06d" "$clip_index").mp4"
    clip_cmd=(ffmpeg -hide_banner -loglevel error -y -ss "$current" -t "$clip_duration_sec" -i "$input_path" -c:v libx264 -preset veryfast -crf 28)
    if [ "$merge_audio" = "true" ]; then
      clip_cmd+=( -c:a aac -b:a 96k )
    else
      clip_cmd+=( -an )
    fi
    clip_cmd+=( "$clip_path" )
    "${clip_cmd[@]}"
    printf "file '%s'\n" "$clip_path" >> "$list_file"
    clip_index=$((clip_index + 1))
    current=$((current + interval_sec))
  done
done < <(printf '%s\n' "$INPUT_PATHS" | tr ',' '\n')

if [ "$clip_index" -eq 0 ]; then
  echo "No clips were generated from input_paths." >&2
  exit 1
fi

ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$list_file" -c copy "$OUTPUT_PATH"

node -e 'console.log(JSON.stringify({output_path: process.env.OUTPUT_PATH, clip_count: Number(process.argv[1]), interval_sec: Number(process.env.INTERVAL_SEC || 300), clip_duration_sec: Number(process.env.CLIP_DURATION_SEC || 2), merge_audio: (process.env.MERGE_AUDIO || "true") === "true"}))' "$clip_index"
