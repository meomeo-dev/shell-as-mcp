#!/usr/bin/env bash
set -euo pipefail

TOOL_URL="${TOOL_URL:?TOOL_URL is required}"
TOOL_OUTPUT_DIR="${TOOL_OUTPUT_DIR:-${HOME}/Downloads}"
TOOL_COOKIES="${TOOL_COOKIES:-}"
# shellcheck source=./_ytdlp_cookies_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_ytdlp_cookies_lib.sh"
TOOL_PROXY="${TOOL_PROXY:-}"
trap '_ytdlp_cookies_cleanup' EXIT

# URL 安全验证
if [[ ! "$TOOL_URL" =~ ^https?:// ]]; then
  printf 'ERROR: TOOL_URL must start with http:// or https://\n' >&2
  exit 1
fi

# 构建命令参数数组
BASE_ARGS=(-vU --js-runtimes node)
[[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
[[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")

mkdir -p "$TOOL_OUTPUT_DIR"

yt-dlp "${BASE_ARGS[@]}" \
  -x --audio-format m4a --audio-quality 0 \
  -o "${TOOL_OUTPUT_DIR}/%(title)s.%(ext)s" \
  "$TOOL_URL"
