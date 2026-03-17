#!/usr/bin/env bash
set -euo pipefail
# _ytdlp_cookies_lib.sh — Shared cookie-store helper for yt-dlp tool scripts
#
# SOURCE this file (do not execute directly):
#   # shellcheck source=./_ytdlp_cookies_lib.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/_ytdlp_cookies_lib.sh"
#
# Prerequisites (caller must set before sourcing):
#   TOOL_COOKIES="${TOOL_COOKIES:-}"   # may be empty
#
# Effects after sourcing:
#   TOOL_COOKIES  — populated with the active cookies file path, or stays empty
#   _COOKIES_TMPFILE — set to the temp decrypted file (empty if none created)
#
# Cleanup: call _ytdlp_cookies_cleanup in your trap EXIT, e.g.:
#   trap '_ytdlp_cookies_cleanup' EXIT
#   trap 'rm -f "${PY_SCRIPT}"; _ytdlp_cookies_cleanup' EXIT

_ENC_COOKIES="${HOME}/.config/shell-as-mcp/ytdlp_cookies.enc"
_COOKIE_KEY="shell-as-mcp-$(hostname)-ytdlp-v1"
_COOKIES_TMPFILE=""
TOOL_COOKIES="${TOOL_COOKIES:-}"

if [[ -z "${TOOL_COOKIES}" && -f "${_ENC_COOKIES}" ]]; then
  _COOKIES_TMPFILE="$(mktemp /tmp/.mcp_ytdlp_ck_XXXXXX)"
  if openssl enc -d -aes-128-cbc -pbkdf2 \
       -pass "pass:${_COOKIE_KEY}" \
       -in "${_ENC_COOKIES}" -out "${_COOKIES_TMPFILE}" 2>/dev/null; then
    TOOL_COOKIES="${_COOKIES_TMPFILE}"
  else
    printf 'WARN: stored cookies could not be decrypted, proceeding without cookies\n' >&2
    rm -f "${_COOKIES_TMPFILE}"
    _COOKIES_TMPFILE=""
  fi
fi

# Cleanup function — include in your trap EXIT to remove the temp file
_ytdlp_cookies_cleanup() {
  [[ -n "${_COOKIES_TMPFILE:-}" ]] && rm -f "${_COOKIES_TMPFILE}"
}
