#!/usr/bin/env bash
set -euo pipefail

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo '{"status":"error","bundle":"ffmpeg","message":"ffmpeg not found"}'
  exit 1
fi

ffmpeg_version="$(ffmpeg -version)"
ffmpeg_version="${ffmpeg_version%%$'\n'*}"
echo "{\"status\":\"ok\",\"bundle\":\"ffmpeg\",\"tool\":\"ffmpeg__healthz\",\"ffmpeg\":\"${ffmpeg_version}\"}"
