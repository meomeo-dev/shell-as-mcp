#!/usr/bin/env bash
set -euo pipefail

# Use a temp symlink to avoid lut3d filter path-escaping issues
tmp_dir="$(mktemp -d)"
safe_lut="${tmp_dir}/lut.cube"
ln -s "${LUT_PATH}" "${safe_lut}"
trap 'rm -rf "${tmp_dir}"' EXIT

ffmpeg -hide_banner -loglevel error -y \
  -i "${INPUT_PATH}" \
  -vf "lut3d=${safe_lut}" \
  -c:a copy \
  "${OUTPUT_PATH}"

node -e 'console.log(JSON.stringify({output_path: process.env.OUTPUT_PATH, lut_path: process.env.LUT_PATH}))'
