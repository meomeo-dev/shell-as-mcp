#!/usr/bin/env bash
set -euo pipefail

TOOL_URL="${TOOL_URL:?TOOL_URL is required}"
TOOL_MAX_COMMENTS="${TOOL_MAX_COMMENTS:-10}"
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
  TOOL_MAX_COMMENTS=10
fi
if (( TOOL_MAX_COMMENTS > 50 )); then
  TOOL_MAX_COMMENTS=50
fi

BASE_ARGS=(-vU --js-runtimes node)
[[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
[[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")

# 将 python 代码写入临时文件，避免与管道同时使用 heredoc（SC2259）
PY_SCRIPT="$(mktemp /tmp/ytdlp_comments_summary_XXXXXX.py)"
trap 'rm -f "${PY_SCRIPT}"; _ytdlp_cookies_cleanup' EXIT

cat > "${PY_SCRIPT}" << 'PYEOF'
import sys, json

max_n = int(sys.argv[1])
raw = sys.stdin.read().strip()
data = {}
for line in raw.splitlines():
    if line.strip():
        data = json.loads(line)
        break

comments = (data.get('comments') or [])[:max_n]
if not comments:
    print('No comments found.')
    sys.exit(0)

for i, c in enumerate(comments, 1):
    author = c.get('author', 'Unknown')
    likes = c.get('like_count') or 0
    text = (c.get('text') or '').replace('\n', ' ')
    if len(text) > 300:
        text = text[:297] + '...'
    is_pinned = c.get('is_pinned', False)
    pin_tag = ' [PINNED]' if is_pinned else ''
    print(f'[{i}] @{author}{pin_tag} (likes:{likes}):')
    print(f'     {text}')
    print()
PYEOF

yt-dlp "${BASE_ARGS[@]}" \
  -j --write-comments --skip-download \
  "$TOOL_URL" \
| python3 "${PY_SCRIPT}" "${TOOL_MAX_COMMENTS}"
