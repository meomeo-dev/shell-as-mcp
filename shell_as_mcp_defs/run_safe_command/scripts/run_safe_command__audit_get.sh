#!/usr/bin/env bash
set -euo pipefail

limit="${TOOL_LIMIT:-20}"
audit_file="${TOOL_AUDIT_FILE:-${TMPDIR:-/tmp}/mcp-shell-run-safe-command-audit.ndjson}"
include_rotated="${TOOL_INCLUDE_ROTATED:-true}"
rotated_file_limit="${TOOL_ROTATED_FILE_LIMIT:-10}"

if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -lt 1 ]] || [[ "$limit" -gt 200 ]]; then
  printf 'ERROR: TOOL_LIMIT must be an integer in range [1, 200].\n' >&2
  exit 1
fi

if [[ "$include_rotated" != "true" && "$include_rotated" != "false" ]]; then
  printf 'ERROR: TOOL_INCLUDE_ROTATED must be true or false.\n' >&2
  exit 1
fi

if ! [[ "$rotated_file_limit" =~ ^[0-9]+$ ]] || [[ "$rotated_file_limit" -lt 1 ]] || [[ "$rotated_file_limit" -gt 50 ]]; then
  printf 'ERROR: TOOL_ROTATED_FILE_LIMIT must be an integer in range [1, 50].\n' >&2
  exit 1
fi

python3 - "$audit_file" "$limit" "$include_rotated" "$rotated_file_limit" <<'PYEOF'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
limit = int(sys.argv[2])
include_rotated = sys.argv[3] == "true"
rotated_file_limit = int(sys.argv[4])

entries = []
parse_errors = 0

files_scanned = []

candidate_files = []
if path.exists():
    candidate_files.append(path)

if include_rotated and path.parent.exists():
    pattern = f"{path.name}." + "*.ndjson"
    rotated = sorted(
        path.parent.glob(pattern),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    candidate_files.extend(rotated[:rotated_file_limit])

for source_file in candidate_files:
    files_scanned.append(str(source_file))
    for raw_line in source_file.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            item = json.loads(line)
            if isinstance(item, dict):
                item.setdefault("_source_file", str(source_file))
            entries.append(item)
        except json.JSONDecodeError:
            parse_errors += 1

payload = {
    "audit_file": str(path),
    "exists": path.exists(),
    "include_rotated": include_rotated,
    "files_scanned": files_scanned,
    "total_entries": len(entries),
    "returned_entries": min(limit, len(entries)),
    "parse_errors": parse_errors,
    "entries": entries[-limit:],
}

print(json.dumps(payload, ensure_ascii=True))
PYEOF
