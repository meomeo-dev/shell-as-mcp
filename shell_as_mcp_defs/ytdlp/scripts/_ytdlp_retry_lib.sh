#!/usr/bin/env bash
set -euo pipefail
# _ytdlp_retry_lib.sh - Shared retry/failure-classification helper for yt-dlp tools

# shellcheck disable=SC2034  # Used by caller scripts after sourcing this lib.
YTDLP_FAILURE_CLASS="unknown"
# shellcheck disable=SC2034  # Used by caller scripts after sourcing this lib.
YTDLP_FAILURE_HINT="Check yt-dlp stderr above for details."

_ytdlp_parse_max_retries() {
  local raw_value="${1:-2}"
  local max_retries="2"

  case "$raw_value" in
    ''|*[!0-9]*)
      printf 'WARN: invalid maxRetries "%s", using default 2\n' "$raw_value" >&2
      max_retries="2"
      ;;
    *)
      max_retries="$raw_value"
      ;;
  esac

  if [[ "$max_retries" -gt 2 ]]; then
    printf 'WARN: maxRetries capped at 2, got %s\n' "$max_retries" >&2
    max_retries="2"
  fi

  printf '%s\n' "$max_retries"
}

_ytdlp_classify_failure() {
  local log_file="$1"
  YTDLP_FAILURE_CLASS="unknown"
  YTDLP_FAILURE_HINT="Check yt-dlp stderr above for details."

  if grep -qiE 'LOGIN_REQUIRED|cookies are no longer valid|Sign in to confirm you.?re not a bot|Use --cookies-from-browser or --cookies' "$log_file"; then
    YTDLP_FAILURE_CLASS="auth_cookie"
    YTDLP_FAILURE_HINT="Refresh cookies via ytdlp__setup_cookies and retry."
    return 0
  fi

  if grep -qiE 'ProxyError|407 Proxy Authentication Required|Connection refused|proxy.*(failed|error)|tunnel connection failed' "$log_file"; then
    YTDLP_FAILURE_CLASS="proxy"
    YTDLP_FAILURE_HINT="Verify TOOL_PROXY connectivity and credentials, then retry."
    return 0
  fi

  if grep -qiE 'timed out|Temporary failure in name resolution|Could not resolve host|Name or service not known|Network is unreachable|TLS|SSL' "$log_file"; then
    # shellcheck disable=SC2034  # Read by sourced caller after classification.
    YTDLP_FAILURE_CLASS="network"
    # shellcheck disable=SC2034  # Read by sourced caller after classification.
    YTDLP_FAILURE_HINT="Check network/DNS/TLS environment and retry."
    return 0
  fi
}

_ytdlp_warn_failure() {
  local attempt="$1"
  local max_retries="$2"
  local failure_class="$3"
  local failure_hint="$4"
  printf 'WARN: tool failed [attempt=%s/%s] [category=%s] hint=%s\n' "$attempt" "$max_retries" "$failure_class" "$failure_hint" >&2
}

_ytdlp_warn_retrying() {
  local attempt="$1"
  local max_retries="$2"
  printf 'WARN: tool failed, retrying (%s/%s)\n' "$attempt" "$max_retries" >&2
}
