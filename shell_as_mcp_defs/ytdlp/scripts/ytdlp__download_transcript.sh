#!/usr/bin/env bash
set -euo pipefail

TOOL_URL="${TOOL_URL:?TOOL_URL is required}"
TOOL_LANGUAGE="${TOOL_LANGUAGE:-en}"
TOOL_COOKIES="${TOOL_COOKIES:-}"
TOOL_OUTPUT_DIR="${TOOL_OUTPUT_DIR:-${YTDLP_OUTPUT_DIR:-}}"
if [[ -z "$TOOL_OUTPUT_DIR" && -n "${SHELL_AS_MCP_OUTPUT_DIR:-}" ]]; then
    TOOL_OUTPUT_DIR="${SHELL_AS_MCP_OUTPUT_DIR%/}/ytdlp"
fi
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

# 创建临时目录并注册清理
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_WORK}"; _ytdlp_cookies_cleanup' EXIT

if [[ -n "$TOOL_OUTPUT_DIR" ]]; then
    mkdir -p "$TOOL_OUTPUT_DIR"
fi

BASE_ARGS=(-v --no-update --js-runtimes node)
[[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
[[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")

_build_base_args() {
    BASE_ARGS=(-v --no-update --js-runtimes node)
    [[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
    [[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")
}

_run_yt_dlp_once() {
    local log_file="$1"
    set +e
    yt-dlp "${BASE_ARGS[@]}" \
        --skip-download --write-subs --write-auto-subs \
        --sub-langs "${TOOL_LANGUAGE}" --sub-format vtt \
        -o "${TMPDIR_WORK}/%(title)s" \
        "$TOOL_URL" 2>&1 | tee "$log_file"
    local yt_exit=${PIPESTATUS[0]}
    set -e
    return "$yt_exit"
}

_build_base_args
attempt=0
while true; do
    attempt=$((attempt + 1))
    run_log="$(mktemp /tmp/.mcp_ytdlp_transcript_XXXXXX)"

    if _run_yt_dlp_once "$run_log"; then
        command rm -f "$run_log"
        break
    fi
    yt_exit=$?

    _ytdlp_classify_failure "$run_log"
    _ytdlp_warn_failure "$attempt" "$MAX_RETRIES" "$YTDLP_FAILURE_CLASS" "$YTDLP_FAILURE_HINT"
    command rm -f "$run_log"

    if [[ "$attempt" -gt "$MAX_RETRIES" ]]; then
        printf 'ERROR: download transcript failed after %s attempt(s) [category=%s]\n' "$attempt" "$YTDLP_FAILURE_CLASS" >&2
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

# VTT → 纯文本（去时间戳、去重复、去 NOTE）
python3 - "${TMPDIR_WORK}" <<'PYEOF'
import os, sys, re, glob

tmpdir = sys.argv[1]
files = glob.glob(tmpdir + '/**/*.vtt', recursive=True)
if not files:
    print('No subtitle file found for the requested language.', file=sys.stderr)
    sys.exit(1)

content = open(files[0], encoding='utf-8').read()
lines = []
for line in content.splitlines():
    stripped = line.strip()
    if not stripped:
        continue
    if stripped == 'WEBVTT':
        continue
    if stripped.startswith('NOTE'):
        continue
    if '-->' in stripped:
        continue
    if re.match(r'^\d{2}:\d{2}', stripped):
        continue
    lines.append(stripped)

# 去重相邻重复行（auto-subs 特征）
deduped = [lines[i] for i in range(len(lines)) if i == 0 or lines[i] != lines[i-1]]

output_dir = os.environ.get('TOOL_OUTPUT_DIR', '').strip()
if output_dir:
    base_name = os.path.splitext(os.path.basename(files[0]))[0]
    out_path = os.path.join(output_dir, f"{base_name}.txt")
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(deduped))
    print(f"SAVED_TRANSCRIPT_PATH={out_path}", file=sys.stderr)

print('\n'.join(deduped))
PYEOF
