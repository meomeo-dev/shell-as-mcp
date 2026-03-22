#!/usr/bin/env bash
set -euo pipefail

TOOL_URL="${TOOL_URL:?TOOL_URL is required}"
TOOL_FIELDS="${TOOL_FIELDS:-}"
TOOL_COOKIES="${TOOL_COOKIES:-}"
# shellcheck source=./_ytdlp_cookies_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_ytdlp_cookies_lib.sh"
# shellcheck source=./_ytdlp_retry_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_ytdlp_retry_lib.sh"
TOOL_PROXY="${TOOL_PROXY:-}"
TOOL_MAX_RETRIES_RAW="${TOOL_MAX_RETRIES:-2}"
MAX_RETRIES="$(_ytdlp_parse_max_retries "$TOOL_MAX_RETRIES_RAW")"
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
SETUP_SCRIPT="${SCRIPT_DIR}/ytdlp__setup_cookies.sh"

# URL 验证
if [[ ! "$TOOL_URL" =~ ^https?:// ]]; then
  printf 'ERROR: TOOL_URL must start with http:// or https://\n' >&2
  exit 1
fi

# fields 白名单字符检查（防止 python 代码注入）
if [[ -n "$TOOL_FIELDS" ]] && ! [[ "$TOOL_FIELDS" =~ ^[a-zA-Z0-9_,[:space:]]+$ ]]; then
  printf 'ERROR: fields parameter contains invalid characters (allowed: letters, digits, underscore, comma)\n' >&2
  exit 1
fi

BASE_ARGS=(-v --no-update --js-runtimes node)
[[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
[[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")

# 将 python 代码写入临时文件，避免与管道同时使用 heredoc（SC2259）
# fields 值通过 sys.argv 传递，不内联到 python 代码中，避免注入
PY_SCRIPT="$(mktemp /tmp/ytdlp_metadata_XXXXXX.py)"
trap 'rm -f "${PY_SCRIPT}"; _ytdlp_cookies_cleanup' EXIT

cat > "${PY_SCRIPT}" << 'PYEOF'
import sys, json

fields_str = sys.argv[1] if len(sys.argv) > 1 else ''
raw = sys.stdin.read().strip()
data = {}
for line in raw.splitlines():
    if line.strip():
        data = json.loads(line)
        break

if fields_str:
    keys = [k.strip() for k in fields_str.split(',') if k.strip()]
    data = {k: data.get(k) for k in keys}

print(json.dumps(data, ensure_ascii=False, indent=2))
PYEOF

_build_base_args() {
  BASE_ARGS=(-v --no-update --js-runtimes node)
  [[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
  [[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")
}

_run_yt_dlp_once() {
  local log_file="$1"
  set +e
  yt-dlp "${BASE_ARGS[@]}" \
    -j --skip-download \
    "$TOOL_URL" \
    2> >(tee "$log_file" >&2) \
  | python3 "${PY_SCRIPT}" "${TOOL_FIELDS}"
  local -a pipe_status=("${PIPESTATUS[@]}")
  local yt_exit="${pipe_status[0]}"
  local py_exit="${pipe_status[1]}"
  set -e
  if [[ "$yt_exit" -eq 0 ]]; then
    return "$py_exit"
  fi
  return "$yt_exit"
}

_build_base_args
attempt=0
while true; do
  attempt=$((attempt + 1))
  run_log="$(mktemp /tmp/.mcp_ytdlp_metadata_XXXXXX)"

  if _run_yt_dlp_once "$run_log"; then
    command rm -f "$run_log"
    exit 0
  fi
  yt_exit=$?

  _ytdlp_classify_failure "$run_log"
  _ytdlp_warn_failure "$attempt" "$MAX_RETRIES" "$YTDLP_FAILURE_CLASS" "$YTDLP_FAILURE_HINT"
  command rm -f "$run_log"

  if [[ "$attempt" -gt "$MAX_RETRIES" ]]; then
    printf 'ERROR: get video metadata failed after %s attempt(s) [category=%s]\n' "$attempt" "$YTDLP_FAILURE_CLASS" >&2
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
