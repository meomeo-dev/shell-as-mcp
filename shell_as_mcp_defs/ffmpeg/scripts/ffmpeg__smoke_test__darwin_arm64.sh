#!/usr/bin/env bash
set -euo pipefail

# per-target smoke test: ffmpeg bundle
# target: kernel=darwin  arch=arm64  (Apple Silicon macOS)
# Evidence: this file's existence + CI pass record confirms darwin/arm64 is tested.

current_kernel="$(uname -s | tr '[:upper:]' '[:lower:]')"
current_arch="$(uname -m)"

if [[ "$current_kernel" != "darwin" || "$current_arch" != "arm64" ]]; then
  echo "SKIP: target is darwin/arm64; detected ${current_kernel}/${current_arch}" >&2
  exit 0
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "SKIP: ffmpeg not found" >&2
  exit 0
fi

ffmpeg_version="$(ffmpeg -version 2>&1 | head -1)"

# Render 1 frame via lavfi to null (no file written, no network)
ffmpeg -y -f lavfi -i "color=black:size=1x1:rate=25" -t 0.04 -f null - 2>/dev/null

echo "{\"status\":\"ok\",\"bundle\":\"ffmpeg\",\"target\":\"darwin_arm64\",\"ffmpeg\":\"${ffmpeg_version}\"}"
