#!/usr/bin/env bash
set -euo pipefail

audit_file="${TOOL_AUDIT_FILE:-${TMPDIR:-/tmp}/mcp-shell-run-safe-command-audit.ndjson}"
max_files="${TOOL_MAX_FILES:-10}"

if ! [[ "$max_files" =~ ^[0-9]+$ ]] || [[ "$max_files" -lt 1 ]] || [[ "$max_files" -gt 100 ]]; then
  printf 'ERROR: TOOL_MAX_FILES must be an integer in range [1, 100].\n' >&2
  exit 1
fi

python3 - "$audit_file" "$max_files" <<'PYEOF'
import datetime
import json
import pathlib
import sys

audit_file = pathlib.Path(sys.argv[1])
max_files = int(sys.argv[2])

if not audit_file.exists():
    print(json.dumps({
        "status": "ok",
        "rotated": False,
        "audit_file": str(audit_file),
        "reason_code": "AUDIT_FILE_NOT_FOUND",
    }, ensure_ascii=True))
    raise SystemExit(0)

now = datetime.datetime.now(datetime.timezone.utc)
suffix = now.strftime("%Y%m%d-%H%M%S")
rotated_path = audit_file.with_name(f"{audit_file.name}.{suffix}.ndjson")
index = 1
while rotated_path.exists():
    rotated_path = audit_file.with_name(f"{audit_file.name}.{suffix}.{index}.ndjson")
    index += 1

audit_file.rename(rotated_path)
audit_file.parent.mkdir(parents=True, exist_ok=True)
audit_file.touch()

pattern = f"{audit_file.name}." + "*.ndjson"
rotated_candidates = sorted(
    audit_file.parent.glob(pattern),
    key=lambda p: p.stat().st_mtime,
    reverse=True,
)

deleted = []
for stale in rotated_candidates[max_files:]:
    try:
        stale.unlink()
        deleted.append(str(stale))
    except OSError:
        continue

print(json.dumps({
    "status": "ok",
    "rotated": True,
    "active_file": str(audit_file),
    "new_rotated_file": str(rotated_path),
    "deleted_files": deleted,
    "retained_rotated_files": min(max_files, len(rotated_candidates)),
}, ensure_ascii=True))
PYEOF
