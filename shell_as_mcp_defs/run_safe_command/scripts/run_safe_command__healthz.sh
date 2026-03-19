#!/usr/bin/env bash
set -euo pipefail

audit_file="${TOOL_AUDIT_FILE:-${TMPDIR:-/tmp}/mcp-shell-run-safe-command-audit.ndjson}"
kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"

python3 - "$audit_file" "$kernel" "$arch" <<'PYEOF'
import json
import os
import pathlib
import shutil
import sys

audit_file = pathlib.Path(sys.argv[1])
kernel = sys.argv[2]
arch = sys.argv[3]

required = {
    "bash": shutil.which("bash") is not None,
    "python3": shutil.which("python3") is not None,
}
optional = {
    "strace": shutil.which("strace") is not None,
    "dtruss": shutil.which("dtruss") is not None,
    "explainshell": shutil.which("explainshell") is not None,
}

warnings = []
if not optional["strace"] and kernel == "darwin":
    warnings.append("strace is unavailable on macOS; trace remains disabled")
if not optional["strace"] and not optional["dtruss"]:
    warnings.append("no optional trace backend detected")

missing = [name for name, ok in required.items() if not ok]
status = "ok" if not missing else "error"

payload = {
    "status": status,
    "bundle": "run_safe_command",
    "tool": "run_safe_command__healthz",
    "kernel": kernel,
    "arch": arch,
    "required": required,
    "optional": optional,
    "capabilities": {
        "darwin_dtruss_ready": kernel == "darwin" and optional["dtruss"] and os.geteuid() == 0,
        "darwin_dtruss_reason_code": "TRACE_DARWIN_PRIVILEGE_REQUIRED"
        if kernel == "darwin" and optional["dtruss"] and os.geteuid() != 0
        else "OK",
        "explain_provider_ready": optional["explainshell"],
    },
    "warnings": warnings,
    "audit": {
        "file": str(audit_file),
        "exists": audit_file.exists(),
        "parent_writable": audit_file.parent.exists() and audit_file.parent.is_dir(),
    },
}

if missing:
    payload["message"] = "missing required dependency: " + ", ".join(missing)

print(json.dumps(payload, ensure_ascii=True))
PYEOF

if ! command -v bash >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  exit 1
fi
