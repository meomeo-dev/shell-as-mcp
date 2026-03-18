#!/usr/bin/env bash
set -euo pipefail

TOOL_QUERY="${TOOL_QUERY:?TOOL_QUERY is required}"
TOOL_MAX_RESULTS="${TOOL_MAX_RESULTS:-10}"
TOOL_OFFSET="${TOOL_OFFSET:-0}"
TOOL_RESPONSE_FORMAT="${TOOL_RESPONSE_FORMAT:-summary}"
TOOL_UPLOAD_DATE_FILTER="${TOOL_UPLOAD_DATE_FILTER:-}"
TOOL_COOKIES="${TOOL_COOKIES:-}"
# shellcheck source=./_ytdlp_cookies_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_ytdlp_cookies_lib.sh"
TOOL_PROXY="${TOOL_PROXY:-}"

# query 安全：禁止换行符，防止参数注入
if [[ "$TOOL_QUERY" == *$'\n'* ]]; then
  printf 'ERROR: query must not contain newlines\n' >&2
  exit 1
fi

# 整数参数验证
if ! [[ "$TOOL_MAX_RESULTS" =~ ^[0-9]+$ ]] || (( TOOL_MAX_RESULTS < 1 )); then
  TOOL_MAX_RESULTS=10
fi
if (( TOOL_MAX_RESULTS > 50 )); then
  TOOL_MAX_RESULTS=50
fi
if ! [[ "$TOOL_OFFSET" =~ ^[0-9]+$ ]]; then
  TOOL_OFFSET=0
fi

FETCH_N=$(( TOOL_MAX_RESULTS + TOOL_OFFSET ))

BASE_ARGS=(-v --no-update --js-runtimes node)
[[ -n "$TOOL_COOKIES" ]] && BASE_ARGS+=(--cookies "$TOOL_COOKIES")
[[ -n "$TOOL_PROXY"   ]] && BASE_ARGS+=(--proxy   "$TOOL_PROXY")

# 日期过滤（使用 yt-dlp 原生相对日期格式，需带单位后缀 "days"）
DATE_ARGS=()
case "${TOOL_UPLOAD_DATE_FILTER}" in
  today) DATE_ARGS+=(--dateafter today) ;;
  week)  DATE_ARGS+=(--dateafter "today-7days") ;;
  month) DATE_ARGS+=(--dateafter "today-30days") ;;
  year)  DATE_ARGS+=(--dateafter "today-365days") ;;
  "")    ;;
  *)
    printf 'WARN: unknown uploadDateFilter "%s", ignored\n' "${TOOL_UPLOAD_DATE_FILTER}" >&2
    ;;
esac

# 将 python 代码写入临时文件，避免与管道同时使用 heredoc（SC2259）
PY_SCRIPT="$(mktemp /tmp/ytdlp_search_XXXXXX.py)"
trap 'rm -f "${PY_SCRIPT}"; _ytdlp_cookies_cleanup' EXIT

cat > "${PY_SCRIPT}" << 'PYEOF'
import sys, json

offset = int(sys.argv[1])
max_n  = int(sys.argv[2])
fmt    = sys.argv[3]

raw = sys.stdin.read().strip()
items = []
for line in raw.splitlines():
    if line.strip():
        try:
            items.append(json.loads(line))
        except json.JSONDecodeError:
            pass

results = items[offset:offset + max_n]

if fmt == 'json':
    out = {
        'total': len(items),
        'count': len(results),
        'offset': offset,
        'videos': [
            {
                'title':    v.get('title', 'N/A'),
                'id':       v.get('id', ''),
                'url':      v.get('url') or v.get('webpage_url', ''),
                'uploader': v.get('uploader') or v.get('channel', ''),
                'duration': v.get('duration'),
            }
            for v in results
        ],
        'has_more': len(items) > offset + max_n,
        'next_offset': offset + max_n,
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))
else:
    for i, v in enumerate(results, offset + 1):
        title    = v.get('title', 'N/A')
        url      = v.get('url') or v.get('webpage_url', '')
        uploader = v.get('uploader') or v.get('channel', '')
        duration = v.get('duration')
        if duration:
            mins, secs = divmod(int(duration), 60)
            dur_str = f'{mins}:{secs:02d}'
        else:
            dur_str = 'N/A'
        print(f'[{i}] {title}')
        print(f'     {url}')
        print(f'     Uploader: {uploader} | Duration: {dur_str}')
        print()
PYEOF

yt-dlp "${BASE_ARGS[@]}" \
  --flat-playlist --skip-download -j \
  "${DATE_ARGS[@]}" \
  "ytsearch${FETCH_N}:${TOOL_QUERY}" \
| python3 "${PY_SCRIPT}" "${TOOL_OFFSET}" "${TOOL_MAX_RESULTS}" "${TOOL_RESPONSE_FORMAT}"
