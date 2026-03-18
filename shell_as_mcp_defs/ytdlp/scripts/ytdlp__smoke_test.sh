#!/usr/bin/env bash
set -euo pipefail

# smoke test for ytdlp bundle
# exit 0 = PASS or SKIP; exit 1 = FAIL

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

echo "{\"status\":\"ok\",\"bundle\":\"ytdlp\",\"yt_dlp\":\"${ytdlp_version}\",\"extractors\":${extractor_count}}"
