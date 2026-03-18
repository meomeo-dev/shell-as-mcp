#!/usr/bin/env bash
set -euo pipefail

# smoke test for ffmpeg bundle
# exit 0 = PASS or SKIP; exit 1 = FAIL

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "SKIP: ffmpeg not found" >&2
  exit 0
fi

ffmpeg_version="$(ffmpeg -version 2>&1 | head -1)"

# Render 1 frame via lavfi to null (no file written, no network)
ffmpeg -y -f lavfi -i "color=black:size=1x1:rate=25" -t 0.04 -f null - 2>/dev/null

echo "{\"status\":\"ok\",\"bundle\":\"ffmpeg\",\"ffmpeg\":\"${ffmpeg_version}\"}"
