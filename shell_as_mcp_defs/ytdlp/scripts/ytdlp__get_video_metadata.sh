#!/usr/bin/env bash
set -euo pipefail

TOOL_URL="${TOOL_URL:?TOOL_URL is required}"
TOOL_FIELDS="${TOOL_FIELDS:-}"
TOOL_COOKIES="${TOOL_COOKIES:-}"
# shellcheck source=./_ytdlp_cookies_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_ytdlp_cookies_lib.sh"
TOOL_PROXY="${TOOL_PROXY:-}"

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

yt-dlp "${BASE_ARGS[@]}" \
  -j --skip-download \
  "$TOOL_URL" \
| python3 "${PY_SCRIPT}" "${TOOL_FIELDS}"
