#!/usr/bin/env bash
set -euo pipefail

format="${TOOL_FORMAT:-markdown}"

case "$format" in
  markdown|json) ;;
  *)
    echo "format must be one of: markdown, json" >&2
    exit 2
    ;;
esac

if [[ "$format" == "markdown" ]]; then
  exec iwencai skillbook --format markdown
fi

raw_output="$(iwencai skillbook --format json)"

printf '%s' "$raw_output" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
if isinstance(payload, dict) and "source_path" in payload:
    payload["source_path"] = "embedded://iwencai/SKILL.md"
print(json.dumps(payload, ensure_ascii=False, indent=2))
'
