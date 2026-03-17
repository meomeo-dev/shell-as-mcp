#!/usr/bin/env bash
set -euo pipefail

if ! command -v yt-dlp >/dev/null 2>&1; then
  echo '{"status":"error","bundle":"ytdlp","message":"yt-dlp not found"}'
  exit 1
fi

ytdlp_version="$(yt-dlp --version)"
echo "{\"status\":\"ok\",\"bundle\":\"ytdlp\",\"tool\":\"ytdlp__healthz\",\"yt_dlp\":\"${ytdlp_version}\"}"
