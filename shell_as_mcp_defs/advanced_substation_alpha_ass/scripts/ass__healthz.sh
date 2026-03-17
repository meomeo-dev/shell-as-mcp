#!/usr/bin/env bash
set -euo pipefail

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo '{"status":"error","bundle":"advanced_substation_alpha_ass","message":"ffmpeg not found"}'
  exit 1
fi

ffmpeg_version="$(ffmpeg -version)"
ffmpeg_version="${ffmpeg_version%%$'\n'*}"
echo "{\"status\":\"ok\",\"bundle\":\"advanced_substation_alpha_ass\",\"tool\":\"ass__healthz\",\"ffmpeg\":\"${ffmpeg_version}\"}"
