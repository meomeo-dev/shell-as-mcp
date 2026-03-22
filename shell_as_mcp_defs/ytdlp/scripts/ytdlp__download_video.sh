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
TOOL_MAX_RETRIES_RAW="${TOOL_MAX_RETRIES:-2}"
trap '_ytdlp_cookies_cleanup' EXIT

case "$TOOL_MAX_RETRIES_RAW" in
  ''|*[!0-9]*)
    printf 'WARN: invalid maxRetries "%s", using default 2\n' "$TOOL_MAX_RETRIES_RAW" >&2
    MAX_RETRIES=2
    ;;
  *)
    MAX_RETRIES="$TOOL_MAX_RETRIES_RAW"
    ;;
esac
if [[ "$MAX_RETRIES" -gt 2 ]]; then
  printf 'WARN: maxRetries capped at 2, got %s\n' "$MAX_RETRIES" >&2
  MAX_RETRIES=2
fi

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
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
SETUP_SCRIPT="${SCRIPT_DIR}/ytdlp__setup_cookies.sh"

mkdir -p "$TOOL_OUTPUT_DIR"

# 时间段参数（须同时提供才生效）
SECTION_ARGS=()
if [[ -n "$TOOL_START_TIME" && -n "$TOOL_END_TIME" ]]; then
  SECTION_ARGS+=(--download-sections "*${TOOL_START_TIME}-${TOOL_END_TIME}")
elif [[ -n "$TOOL_START_TIME" || -n "$TOOL_END_TIME" ]]; then
  printf 'WARN: startTime and endTime must both be provided to trim video; ignored.\n' >&2
fi

_build_base_args() {
  BASE_ARGS=(-v --no-update --js-runtimes node)
  [[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
  [[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")
}

_run_yt_dlp_once() {
  local log_file="$1"
  set +e
  if [[ ${#SECTION_ARGS[@]} -gt 0 ]]; then
    yt-dlp "${BASE_ARGS[@]}" \
      -f "$FORMAT" \
      -o "${TOOL_OUTPUT_DIR}/%(title)s.%(ext)s" \
      "${SECTION_ARGS[@]}" \
      "$TOOL_URL" 2>&1 | tee "$log_file"
  else
    yt-dlp "${BASE_ARGS[@]}" \
      -f "$FORMAT" \
      -o "${TOOL_OUTPUT_DIR}/%(title)s.%(ext)s" \
      "$TOOL_URL" 2>&1 | tee "$log_file"
  fi
  local yt_exit=${PIPESTATUS[0]}
  set -e
  return "$yt_exit"
}

_classify_failure() {
  local log_file="$1"
  FAILURE_CLASS="unknown"
  FAILURE_HINT="Check yt-dlp stderr above for details."

  if grep -qiE 'LOGIN_REQUIRED|cookies are no longer valid|Sign in to confirm you.?re not a bot|Use --cookies-from-browser or --cookies' "$log_file"; then
    FAILURE_CLASS="auth_cookie"
    FAILURE_HINT="Refresh cookies via ytdlp__setup_cookies and retry."
    return 0
  fi

  if grep -qiE 'ProxyError|407 Proxy Authentication Required|Connection refused|proxy.*(failed|error)|tunnel connection failed' "$log_file"; then
    FAILURE_CLASS="proxy"
    FAILURE_HINT="Verify TOOL_PROXY connectivity and credentials, then retry."
    return 0
  fi

  if grep -qiE 'timed out|Temporary failure in name resolution|Could not resolve host|Name or service not known|Network is unreachable|TLS|SSL' "$log_file"; then
    FAILURE_CLASS="network"
    FAILURE_HINT="Check network/DNS/TLS environment and retry."
    return 0
  fi
}

_build_base_args
attempt=0
while true; do
  attempt=$((attempt + 1))
  run_log="$(mktemp /tmp/.mcp_ytdlp_dl_XXXXXX)"

  if _run_yt_dlp_once "$run_log"; then
    command rm -f "$run_log"
    exit 0
  fi
  yt_exit=$?

  need_cookie_setup=false
  _classify_failure "$run_log"
  if [[ "$FAILURE_CLASS" == "auth_cookie" ]]; then
    need_cookie_setup=true
  fi

  printf 'WARN: download failed [category=%s] hint=%s\n' "$FAILURE_CLASS" "$FAILURE_HINT" >&2
  command rm -f "$run_log"

  if [[ "$attempt" -gt "$MAX_RETRIES" ]]; then
    printf 'ERROR: download failed after %s attempt(s) [category=%s]\n' "$attempt" "$FAILURE_CLASS" >&2
    exit "$yt_exit"
  fi

  printf 'WARN: download failed, retrying (%s/%s)\n' "$attempt" "$MAX_RETRIES" >&2

  if [[ "$need_cookie_setup" == "true" ]]; then
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
      exit "$yt_exit"
    fi
  fi
done
