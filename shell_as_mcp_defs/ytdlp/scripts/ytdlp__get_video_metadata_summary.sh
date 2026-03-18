#!/usr/bin/env bash
set -euo pipefail

TOOL_URL="${TOOL_URL:?TOOL_URL is required}"
TOOL_COOKIES="${TOOL_COOKIES:-}"
# shellcheck source=./_ytdlp_cookies_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_ytdlp_cookies_lib.sh"
TOOL_PROXY="${TOOL_PROXY:-}"

# URL 验证
if [[ ! "$TOOL_URL" =~ ^https?:// ]]; then
  printf 'ERROR: TOOL_URL must start with http:// or https://\n' >&2
  exit 1
fi

BASE_ARGS=(-v --no-update --js-runtimes node)
[[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
[[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")

# 将 python 代码写入临时文件，避免与管道同时使用 heredoc（SC2259）
PY_SCRIPT="$(mktemp /tmp/ytdlp_meta_summary_XXXXXX.py)"
trap 'rm -f "${PY_SCRIPT}"; _ytdlp_cookies_cleanup' EXIT

cat > "${PY_SCRIPT}" << 'PYEOF'
import sys, json, datetime

raw = sys.stdin.read().strip()
d = {}
for line in raw.splitlines():
    if line.strip():
        d = json.loads(line)
        break

duration = d.get('duration') or 0
dur_str = str(datetime.timedelta(seconds=int(duration)))

upload = d.get('upload_date', '') or ''
if len(upload) == 8:
    upload = f'{upload[:4]}-{upload[4:6]}-{upload[6:]}'

view_count = d.get('view_count')
view_str = f'{view_count:,}' if isinstance(view_count, int) else str(view_count or 'N/A')

tags = d.get('tags') or []
tags_str = ', '.join(tags[:5]) if tags else 'N/A'

desc = (d.get('description') or '')[:500]

print(f"Title    : {d.get('title', 'N/A')}")
print(f"Channel  : {d.get('uploader', d.get('channel', 'N/A'))}")
print(f"Duration : {dur_str}")
print(f"Uploaded : {upload or 'N/A'}")
print(f"Views    : {view_str}")
print(f"Likes    : {d.get('like_count', 'N/A')}")
print(f"Tags     : {tags_str}")
print(f"URL      : {d.get('webpage_url', 'N/A')}")
print(f"")
print(f"Description:")
print(desc)
PYEOF

yt-dlp "${BASE_ARGS[@]}" \
  -j --skip-download \
  "$TOOL_URL" \
| python3 "${PY_SCRIPT}"
