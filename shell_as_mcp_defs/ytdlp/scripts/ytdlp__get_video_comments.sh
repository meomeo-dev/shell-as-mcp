#!/usr/bin/env bash
set -euo pipefail

TOOL_URL="${TOOL_URL:?TOOL_URL is required}"
TOOL_MAX_COMMENTS="${TOOL_MAX_COMMENTS:-100}"
TOOL_SORT_ORDER="${TOOL_SORT_ORDER:-top}"
TOOL_COOKIES="${TOOL_COOKIES:-}"
# shellcheck source=./_ytdlp_cookies_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_ytdlp_cookies_lib.sh"
TOOL_PROXY="${TOOL_PROXY:-}"

# URL 验证
if [[ ! "$TOOL_URL" =~ ^https?:// ]]; then
  printf 'ERROR: TOOL_URL must start with http:// or https://\n' >&2
  exit 1
fi

# 整数验证
if ! [[ "$TOOL_MAX_COMMENTS" =~ ^[0-9]+$ ]] || (( TOOL_MAX_COMMENTS < 1 )); then
  printf 'WARN: invalid maxComments "%s", using 100\n' "$TOOL_MAX_COMMENTS" >&2
  TOOL_MAX_COMMENTS=100
fi
if (( TOOL_MAX_COMMENTS > 5000 )); then
  TOOL_MAX_COMMENTS=5000
fi

BASE_ARGS=(-vU --js-runtimes node)
[[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
[[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")

SORT_ARGS=()
if [[ "${TOOL_SORT_ORDER}" == "new" ]]; then
  SORT_ARGS+=(--extractor-args "youtube:comment_sort=new")
fi

MAX_N="${TOOL_MAX_COMMENTS}"

# 将 Python 解析脚本写入临时文件，避免 pipe + heredoc 双重 stdin 冲突（SC2259）
PY_SCRIPT="$(mktemp --suffix=.py)"
trap 'rm -f "${PY_SCRIPT}"; _ytdlp_cookies_cleanup' EXIT
cat > "${PY_SCRIPT}" << 'PYEOF'
import sys, json

max_n = int(sys.argv[1])
raw = sys.stdin.read().strip()
# yt-dlp -j 输出可能含多行(playlist)，取第一个 JSON 对象
for line in raw.splitlines():
    if line.strip():
        data = json.loads(line)
        break
else:
    print('{}')
    sys.exit(0)

comments = data.get('comments') or []
result = comments[:max_n]
out = {
    'count': len(result),
    'has_more': len(comments) > max_n,
    'comments': result
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PYEOF

yt-dlp "${BASE_ARGS[@]}" \
  -j --write-comments --skip-download \
  "${SORT_ARGS[@]}" \
  "$TOOL_URL" \
| python3 "${PY_SCRIPT}" "${MAX_N}"
