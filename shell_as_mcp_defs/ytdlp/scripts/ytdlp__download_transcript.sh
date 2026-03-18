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
TOOL_PROXY="${TOOL_PROXY:-}"

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

# 下载 VTT 字幕
yt-dlp "${BASE_ARGS[@]}" \
  --skip-download --write-subs --write-auto-subs \
  --sub-langs "${TOOL_LANGUAGE}" --sub-format vtt \
  -o "${TMPDIR_WORK}/%(title)s" \
  "$TOOL_URL"

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
