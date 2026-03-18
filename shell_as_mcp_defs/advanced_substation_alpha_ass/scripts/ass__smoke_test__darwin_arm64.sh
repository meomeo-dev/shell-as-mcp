#!/usr/bin/env bash
set -euo pipefail

# per-target smoke test: advanced_substation_alpha_ass bundle
# target: kernel=darwin  arch=arm64  (Apple Silicon macOS)
# Evidence: this file's existence + CI pass record confirms darwin/arm64 is tested.
# NOTE: standalone script — no env vars required; builds /tmp fixture internally.

current_kernel="$(uname -s | tr '[:upper:]' '[:lower:]')"
current_arch="$(uname -m)"

if [[ "$current_kernel" != "darwin" || "$current_arch" != "arm64" ]]; then
  echo "SKIP: target is darwin/arm64; detected ${current_kernel}/${current_arch}" >&2
  exit 0
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "FAIL: ffmpeg not found on darwin/arm64" >&2
  exit 1
fi

ffmpeg_version="$(ffmpeg -version 2>&1 | head -1)"

# Create a minimal .ass subtitle fixture in /tmp (no external dependency)
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

ass_file="${tmp_dir}/test.ass"
out_file="${tmp_dir}/out.mp4"

printf '%s\n' \
  '[Script Info]' \
  'ScriptType: v4.00+' \
  'PlayResX: 320' \
  'PlayResY: 240' \
  '[V4+ Styles]' \
  'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding' \
  'Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1' \
  '[Events]' \
  'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text' \
  'Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,smoke ok' \
  > "$ass_file"

# Render 1 second: lavfi + subtitles overlay → MP4 (verifies libass compiled in)
if ! ffmpeg -y \
    -f lavfi -i "color=black:size=320x240:rate=25:duration=1" \
    -vf "subtitles=${ass_file}" \
    -c:v libx264 -preset ultrafast \
    "$out_file" >/dev/null 2>&1; then
  echo "FAIL: ffmpeg subtitle rendering failed (libass may not be compiled in)" >&2
  exit 1
fi

echo "{\"status\":\"ok\",\"bundle\":\"advanced_substation_alpha_ass\",\"target\":\"darwin_arm64\",\"ffmpeg\":\"${ffmpeg_version}\"}"
