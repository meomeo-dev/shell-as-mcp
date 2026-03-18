#!/usr/bin/env bash
set -euo pipefail

TOOL_URL="${TOOL_URL:?TOOL_URL is required}"
TOOL_RESOLUTION="${TOOL_RESOLUTION:-720p}"
TOOL_START_TIME="${TOOL_START_TIME:-}"
TOOL_END_TIME="${TOOL_END_TIME:-}"
TOOL_OUTPUT_DIR="${TOOL_OUTPUT_DIR:-${HOME}/Downloads}"
TOOL_COOKIES="${TOOL_COOKIES:-}"
# shellcheck source=./_ytdlp_cookies_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_ytdlp_cookies_lib.sh"
TOOL_PROXY="${TOOL_PROXY:-}"
trap '_ytdlp_cookies_cleanup' EXIT

# URL 验证
if [[ ! "$TOOL_URL" =~ ^https?:// ]]; then
  printf 'ERROR: TOOL_URL must start with http:// or https://\n' >&2
  exit 1
fi

# 分辨率校验并映射格式
case "$TOOL_RESOLUTION" in
  480p)  FORMAT="bestvideo[height<=480]+bestaudio/best[height<=480]" ;;
  720p)  FORMAT="bestvideo[height<=720]+bestaudio/best[height<=720]" ;;
  1080p) FORMAT="bestvideo[height<=1080]+bestaudio/best[height<=1080]" ;;
  best)  FORMAT="bestvideo+bestaudio/best" ;;
  *)
    printf 'WARN: unknown resolution "%s", falling back to 720p\n' "$TOOL_RESOLUTION" >&2
    FORMAT="bestvideo[height<=720]+bestaudio/best[height<=720]"
    ;;
esac

BASE_ARGS=(-v --no-update --js-runtimes node)
[[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
[[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")

mkdir -p "$TOOL_OUTPUT_DIR"

# 时间段参数（须同时提供才生效）
SECTION_ARGS=()
if [[ -n "$TOOL_START_TIME" && -n "$TOOL_END_TIME" ]]; then
  SECTION_ARGS+=(--download-sections "*${TOOL_START_TIME}-${TOOL_END_TIME}")
elif [[ -n "$TOOL_START_TIME" || -n "$TOOL_END_TIME" ]]; then
  printf 'WARN: startTime and endTime must both be provided to trim video; ignored.\n' >&2
fi

yt-dlp "${BASE_ARGS[@]}" \
  -f "$FORMAT" \
  -o "${TOOL_OUTPUT_DIR}/%(title)s.%(ext)s" \
  "${SECTION_ARGS[@]}" \
  "$TOOL_URL"
