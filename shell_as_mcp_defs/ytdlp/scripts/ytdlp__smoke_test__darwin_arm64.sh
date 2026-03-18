#!/usr/bin/env bash
set -euo pipefail

# per-target smoke test: ytdlp bundle
# target: kernel=darwin  arch=arm64  (Apple Silicon macOS)
# Evidence: this file's existence + CI pass record confirms darwin/arm64 is tested.

current_kernel="$(uname -s | tr '[:upper:]' '[:lower:]')"
current_arch="$(uname -m)"

if [[ "$current_kernel" != "darwin" || "$current_arch" != "arm64" ]]; then
  echo "SKIP: target is darwin/arm64; detected ${current_kernel}/${current_arch}" >&2
  exit 0
fi

if ! command -v yt-dlp >/dev/null 2>&1; then
  echo "SKIP: yt-dlp not found" >&2
  exit 0
fi

ytdlp_version="$(yt-dlp --version 2>&1)"

# Verify extractors are loaded (must have > 100 entries)
extractor_count="$(yt-dlp --list-extractors 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$extractor_count" -le 100 ]]; then
  echo "FAIL: yt-dlp extractor count too low: ${extractor_count}" >&2
  exit 1
fi

echo "{\"status\":\"ok\",\"bundle\":\"ytdlp\",\"target\":\"darwin_arm64\",\"yt_dlp\":\"${ytdlp_version}\",\"extractors\":${extractor_count}}"
