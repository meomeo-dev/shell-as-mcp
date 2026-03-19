#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
execute_script="$script_dir/run_safe_command__execute.sh"
healthz_script="$script_dir/run_safe_command__healthz.sh"
audit_rotate_script="$script_dir/run_safe_command__audit_rotate.sh"
audit_get_script="$script_dir/run_safe_command__audit_get.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not found" >&2
  exit 0
fi

healthz_output="$(bash "$healthz_script" 2>/dev/null || true)"
if [[ -z "$healthz_output" ]]; then
  echo "ERROR: healthz produced empty output" >&2
  exit 1
fi

audit_file="$(mktemp)"

run_output="$(
  TOOL_COMMAND="echo" \
  TOOL_ARGS_JSON='["smoke-ok"]' \
  TOOL_WORKING_DIR="$repo_root" \
  TOOL_DEFAULT_APPROVALS="1" \
  TOOL_REQUEST_ID="smoke-generic" \
  TOOL_CONFIRM_ACTION="false" \
  TOOL_AUDIT_FILE="$audit_file" \
  bash "$execute_script"
)"

full_output="$(
  TOOL_COMMAND="echo" \
  TOOL_ARGS_JSON='["smoke-ok-full"]' \
  TOOL_WORKING_DIR="$repo_root" \
  TOOL_DEFAULT_APPROVALS="1" \
  TOOL_REQUEST_ID="smoke-full" \
  TOOL_CONFIRM_ACTION="false" \
  TOOL_EXECUTE_OUTPUT_MODE="full" \
  TOOL_AUDIT_FILE="$audit_file" \
  bash "$execute_script"
)"

risky_execute_output="$(
  TOOL_COMMAND="rm" \
  TOOL_ARGS_JSON='["-f", "./non-existent-smoke-file"]' \
  TOOL_WORKING_DIR="$repo_root" \
  TOOL_DEFAULT_APPROVALS="1" \
  TOOL_CONFIRM_ACTION="true" \
  TOOL_TRACE_MODE="none" \
  TOOL_AUDIT_FILE="$audit_file" \
  bash "$execute_script"
)"

audit_get_output="$(
  TOOL_AUDIT_FILE="$audit_file" \
  TOOL_LIMIT="20" \
  TOOL_INCLUDE_ROTATED="false" \
  bash "$audit_get_script"
)"

rotate_output="$(
  TOOL_AUDIT_FILE="$audit_file" \
  TOOL_MAX_FILES="5" \
  bash "$audit_rotate_script"
)"

python3 - "$run_output" "$full_output" "$risky_execute_output" "$rotate_output" "$audit_get_output" <<'PYEOF'
import json
import sys

payload = json.loads(sys.argv[1])
full_payload = json.loads(sys.argv[2])
risky_payload = json.loads(sys.argv[3])
rotate_payload = json.loads(sys.argv[4])
audit_get_payload = json.loads(sys.argv[5])

required = ["request", "execution", "authorization", "audit"]
missing = [key for key in required if key not in payload]
if missing:
    print("missing keys: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)

for forbidden in ["trace", "explanation", "security"]:
  if forbidden in payload:
    print(f"concise payload unexpectedly contains {forbidden}", file=sys.stderr)
    sys.exit(1)

execution = payload.get("execution", {})
request = payload.get("request", {})
if request.get("command") != "echo":
    print("unexpected request.command", file=sys.stderr)
    sys.exit(1)
if execution.get("exit_code") != 0:
    print("unexpected execution.exit_code", file=sys.stderr)
    sys.exit(1)

concise_auth = payload.get("authorization", {})
if set(concise_auth.keys()) != {"verified", "reason_code", "source"}:
  print("concise authorization shape mismatch", file=sys.stderr)
  sys.exit(1)

full_required = ["request", "security", "authorization", "execution", "trace", "explanation", "audit"]
full_missing = [key for key in full_required if key not in full_payload]
if full_missing:
  print("full output missing keys: " + ", ".join(full_missing), file=sys.stderr)
  sys.exit(1)

auth = risky_payload.get("authorization", {})
if auth.get("verified") is not True:
  print("authorization state is not verified", file=sys.stderr)
  sys.exit(1)
if auth.get("source") not in {"confirm_action", "wkwebview", "osa", "default_approvals", "none"}:
  print("authorization source is invalid", file=sys.stderr)
  sys.exit(1)

base_auth = payload.get("authorization", {})
if base_auth.get("source") not in {"default_approvals", "none"}:
  print("base authorization source is invalid", file=sys.stderr)
  sys.exit(1)

if rotate_payload.get("status") != "ok":
  print("audit rotate failed", file=sys.stderr)
  sys.exit(1)

entries = audit_get_payload.get("entries", [])
if not isinstance(entries, list) or not entries:
  print("audit_get entries are empty", file=sys.stderr)
  sys.exit(1)

record_id = payload.get("audit", {}).get("record_id")
if not record_id:
  print("missing record_id in execute output", file=sys.stderr)
  sys.exit(1)

entry = None
for item in entries:
  if isinstance(item, dict) and item.get("record_id") == record_id:
    entry = item
    break

if entry is None:
  print("record_id not found in audit_get entries", file=sys.stderr)
  sys.exit(1)

recoverable = set()
for key in ["request", "execution", "security"]:
  if key in entry and isinstance(entry.get(key), dict):
    recoverable.add(key)
if isinstance(entry.get("authorization"), dict) or isinstance(entry.get("auth"), dict):
  recoverable.add("auth")

expected = {"request", "auth", "execution", "security"}
if recoverable != expected:
  print(f"recoverable keyset mismatch: {sorted(recoverable)}", file=sys.stderr)
  sys.exit(1)

print(json.dumps({"status": "ok", "bundle": "run_safe_command", "mode": "generic"}, ensure_ascii=True))
PYEOF

rm -f "$audit_file"
