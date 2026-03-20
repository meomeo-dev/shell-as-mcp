#!/usr/bin/env bash
set -euo pipefail

# Use a temp symlink to avoid ffmpeg subtitles filter path-escaping issues
tmp_dir="$(mktemp -d)"
sub_ext="${SUBTITLE_PATH##*.}"
safe_sub="${tmp_dir}/subtitle.${sub_ext}"
ln -s "${SUBTITLE_PATH}" "${safe_sub}"
trap 'rm -rf "${tmp_dir}"' EXIT

vf_arg="subtitles=${safe_sub}"
if [ -n "${FORCE_STYLE:-}" ]; then
  vf_arg="${vf_arg}:force_style='${FORCE_STYLE}'"
fi

ffmpeg -hide_banner -loglevel error -y \
  -i "${INPUT_PATH}" \
  -vf "${vf_arg}" \
  -c:v libx264 -preset medium -crf 18 \
  -c:a copy \
  "${OUTPUT_PATH}"

node -e 'console.log(JSON.stringify({output_path: process.env.OUTPUT_PATH, subtitle_path: process.env.SUBTITLE_PATH, force_style: process.env.FORCE_STYLE || null}))'
