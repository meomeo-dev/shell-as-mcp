#!/usr/bin/env bash
set -euo pipefail

TOOL_URL="${TOOL_URL:?TOOL_URL is required}"
TOOL_OUTPUT_DIR="${TOOL_OUTPUT_DIR:-${HOME}/Downloads}"
TOOL_COOKIES="${TOOL_COOKIES:-}"
# shellcheck source=./_ytdlp_cookies_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_ytdlp_cookies_lib.sh"
# shellcheck source=./_ytdlp_retry_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_ytdlp_retry_lib.sh"
TOOL_PROXY="${TOOL_PROXY:-}"
TOOL_MAX_RETRIES_RAW="${TOOL_MAX_RETRIES:-2}"
MAX_RETRIES="$(_ytdlp_parse_max_retries "$TOOL_MAX_RETRIES_RAW")"
trap '_ytdlp_cookies_cleanup' EXIT

# URL 安全验证
if [[ ! "$TOOL_URL" =~ ^https?:// ]]; then
  printf 'ERROR: TOOL_URL must start with http:// or https://\n' >&2
  exit 1
fi

# 构建命令参数数组
BASE_ARGS=(-v --no-update --js-runtimes node)
[[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
[[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
SETUP_SCRIPT="${SCRIPT_DIR}/ytdlp__setup_cookies.sh"

mkdir -p "$TOOL_OUTPUT_DIR"

_build_base_args() {
  BASE_ARGS=(-v --no-update --js-runtimes node)
  [[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
  [[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")
}

_run_yt_dlp_once() {
  local log_file="$1"
  set +e
  yt-dlp "${BASE_ARGS[@]}" \
    -x --audio-format m4a --audio-quality 0 \
    -o "${TOOL_OUTPUT_DIR}/%(title)s.%(ext)s" \
    "$TOOL_URL" 2>&1 | tee "$log_file"
  local yt_exit=${PIPESTATUS[0]}
  set -e
  return "$yt_exit"
}

_build_base_args
attempt=0
while true; do
  attempt=$((attempt + 1))
  run_log="$(mktemp /tmp/.mcp_ytdlp_audio_XXXXXX)"

  if _run_yt_dlp_once "$run_log"; then
    command rm -f "$run_log"
    exit 0
  fi
  yt_exit=$?

  _ytdlp_classify_failure "$run_log"
  _ytdlp_warn_failure "$attempt" "$MAX_RETRIES" "$YTDLP_FAILURE_CLASS" "$YTDLP_FAILURE_HINT"
  command rm -f "$run_log"

  if [[ "$attempt" -gt "$MAX_RETRIES" ]]; then
    printf 'ERROR: download audio failed after %s attempt(s) [category=%s]\n' "$attempt" "$YTDLP_FAILURE_CLASS" >&2
    exit "$yt_exit"
  fi

  _ytdlp_warn_retrying "$attempt" "$MAX_RETRIES"

  if [[ "$YTDLP_FAILURE_CLASS" == "auth_cookie" ]]; then
    if [[ -f "$SETUP_SCRIPT" ]]; then
      printf 'WARN: auth/cookie challenge detected, launching cookie setup before retry\n' >&2
      if ! bash "$SETUP_SCRIPT"; then
        printf 'WARN: cookie setup failed or canceled; stop retrying\n' >&2
        exit "$yt_exit"
      fi
      _ytdlp_cookies_cleanup
      TOOL_COOKIES=""
      # shellcheck source=./_ytdlp_cookies_lib.sh
      source "${SCRIPT_DIR}/_ytdlp_cookies_lib.sh"
      _build_base_args
    else
      printf 'WARN: cookie setup script not found: %s\n' "$SETUP_SCRIPT" >&2
      printf 'WARN: run ytdlp__setup_cookies and retry this tool\n' >&2
      exit "$yt_exit"
    fi
  fi
done
