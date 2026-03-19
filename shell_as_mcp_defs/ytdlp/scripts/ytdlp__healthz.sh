#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"
reasons=()

if ! command -v yt-dlp >/dev/null 2>&1; then
  reasons+=("missing command: yt-dlp")
fi
if ! command -v python3 >/dev/null 2>&1; then
  reasons+=("missing command: python3")
fi
if ! command -v node >/dev/null 2>&1; then
  reasons+=("missing command: node (required by yt-dlp --js-runtimes)")
fi
if [[ ! -f "$script_dir/_ytdlp_cookies_lib.sh" ]]; then
  reasons+=("missing file: _ytdlp_cookies_lib.sh")
fi

if [[ "${#reasons[@]}" -gt 0 ]]; then
  reason_text="$(printf '%s; ' "${reasons[@]}")"
  reason_text="${reason_text%; }"
  echo "{\"status\":\"error\",\"bundle\":\"ytdlp\",\"tool\":\"ytdlp__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\",\"message\":\"dependencies not ready: ${reason_text}\"}"
  exit 1
fi

ytdlp_version="$(yt-dlp --version)"
echo "{\"status\":\"ok\",\"bundle\":\"ytdlp\",\"tool\":\"ytdlp__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\",\"yt_dlp\":\"${ytdlp_version}\"}"
