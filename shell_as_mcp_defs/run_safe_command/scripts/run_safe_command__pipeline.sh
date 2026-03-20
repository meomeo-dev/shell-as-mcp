#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# run_safe_command__pipeline.sh — Safe Shell Pipeline MCP Tool
#
# Accepts structured stages_json (array of {command, args} objects) and
# executes them as a pipeline via Python subprocess chaining. No shell eval
# of user data is performed. Three-layer allowlist enforces read-only commands.
# ---------------------------------------------------------------------------

# --- Parameter Binding (env vars only; no positional $1/$2 usage) ---
stages_json="${TOOL_STAGES_JSON:?TOOL_STAGES_JSON environment variable is required}"
working_dir="${TOOL_WORKING_DIR:?TOOL_WORKING_DIR environment variable is required}"
confirm_action="${TOOL_CONFIRM_ACTION:-false}"
request_id="${TOOL_REQUEST_ID:-}"
default_approvals_raw="${TOOL_DEFAULT_APPROVALS:-${DEFAULT_APPROVALS:-}}"
auth_prompt_timeout_ms="${TOOL_AUTH_PROMPT_TIMEOUT_MS:-45000}"
execute_output_mode_raw="${TOOL_EXECUTE_OUTPUT_MODE:-concise}"
max_stages="${TOOL_MAX_STAGES:-10}"
max_args_per_stage="${TOOL_MAX_ARGS_PER_STAGE:-32}"
audit_file="${TOOL_AUDIT_FILE:-${TMPDIR:-/tmp}/mcp-shell-run-safe-command-audit.ndjson}"
audit_rotate_max_bytes="${TOOL_AUDIT_ROTATE_MAX_BYTES:-1048576}"
audit_rotate_max_files="${TOOL_AUDIT_ROTATE_MAX_FILES:-10}"
audit_rotate_daily="${TOOL_AUDIT_ROTATE_DAILY:-false}"

# --- Parameter Validation ---

execute_output_mode="$(printf '%s' "$execute_output_mode_raw" | tr '[:upper:]' '[:lower:]')"
if [[ "$execute_output_mode" != "concise" && "$execute_output_mode" != "full" ]]; then
    execute_output_mode="concise"
fi

if ! [[ "$max_stages" =~ ^[0-9]+$ ]] || [[ "$max_stages" -lt 1 ]] || [[ "$max_stages" -gt 50 ]]; then
    printf 'ERROR: TOOL_MAX_STAGES must be an integer in range [1, 50].\n' >&2
    exit 1
fi

if ! [[ "$max_args_per_stage" =~ ^[0-9]+$ ]] || [[ "$max_args_per_stage" -lt 1 ]] || [[ "$max_args_per_stage" -gt 128 ]]; then
    printf 'ERROR: TOOL_MAX_ARGS_PER_STAGE must be an integer in range [1, 128].\n' >&2
    exit 1
fi

if ! [[ "$auth_prompt_timeout_ms" =~ ^[0-9]+$ ]] || [[ "$auth_prompt_timeout_ms" -lt 5000 ]] || [[ "$auth_prompt_timeout_ms" -gt 120000 ]]; then
    printf 'ERROR: TOOL_AUTH_PROMPT_TIMEOUT_MS must be an integer in range [5000, 120000].\n' >&2
    exit 1
fi

if ! [[ "$audit_rotate_max_bytes" =~ ^[0-9]+$ ]] || [[ "$audit_rotate_max_bytes" -lt 1024 ]] || [[ "$audit_rotate_max_bytes" -gt 104857600 ]]; then
    printf 'ERROR: TOOL_AUDIT_ROTATE_MAX_BYTES must be an integer in range [1024, 104857600].\n' >&2
    exit 1
fi

if ! [[ "$audit_rotate_max_files" =~ ^[0-9]+$ ]] || [[ "$audit_rotate_max_files" -lt 1 ]] || [[ "$audit_rotate_max_files" -gt 100 ]]; then
    printf 'ERROR: TOOL_AUDIT_ROTATE_MAX_FILES must be an integer in range [1, 100].\n' >&2
    exit 1
fi

if [[ "$audit_rotate_daily" != "true" && "$audit_rotate_daily" != "false" ]]; then
    printf 'ERROR: TOOL_AUDIT_ROTATE_DAILY must be true or false.\n' >&2
    exit 1
fi

if [[ "$working_dir" != /* ]]; then
    printf 'ERROR: working_dir must be an absolute path.\n' >&2
    exit 1
fi

if ! resolved_working_dir="$(cd "$working_dir" && pwd -P 2>/dev/null)"; then
    printf 'ERROR: working_dir does not exist or is not accessible: %s\n' "$working_dir" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    printf 'ERROR: python3 is required for stages_json parsing and JSON response rendering.\n' >&2
    exit 1
fi

# --- Temp files & cleanup trap ---
parsed_stages_file="$(mktemp)"
warnings_file="$(mktemp)"
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "${parsed_stages_file:-}" "${warnings_file:-}" "${stdout_file:-}" "${stderr_file:-}"' EXIT

# --- Stage 1+2: stages_json validation via Python (allowlist + args checks) ---
python3 - "$stages_json" "$max_stages" "$max_args_per_stage" "$resolved_working_dir" <<'PYEOF' > "$parsed_stages_file"
import json
import re
import sys

stages_raw = sys.argv[1]
max_st = int(sys.argv[2])
max_ap = int(sys.argv[3])
resolved_wd = sys.argv[4]

# Layer 2: Pipeline command semantic allowlist (read-only processing commands only).
# Excludes rm, mv, dd, curl, wget, python3, bash, sh, etc.
PIPELINE_ALLOWLIST = frozenset([
    "ps", "grep", "awk", "sed", "cut", "sort", "uniq", "wc",
    "head", "tail", "cat", "echo", "tr", "xargs", "find", "ls",
    "du", "df", "date", "env", "printenv", "uname", "hostname",
    "id", "whoami", "pwd", "dirname", "basename", "column",
    "tee", "paste", "join", "comm", "diff", "nl", "fmt", "fold",
])

# Layer 1: Command charset allowlist (inherited from execute.sh)
CMD_CHARSET_RE = re.compile(r'^[a-zA-Z0-9._+:-]+$')

try:
    stages = json.loads(stages_raw)
except json.JSONDecodeError as exc:
    print(f"ERROR: stages_json must be valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(stages, list):
    print("ERROR: stages_json must be a JSON array", file=sys.stderr)
    sys.exit(1)

if len(stages) == 0:
    print("ERROR: stages_json must contain at least 1 stage", file=sys.stderr)
    sys.exit(1)

if len(stages) > max_st:
    print(f"ERROR: stages_json too many stages. max={max_st}", file=sys.stderr)
    sys.exit(1)

for idx, stage in enumerate(stages):
    if not isinstance(stage, dict):
        print(f"ERROR: stages_json[{idx}] must be an object", file=sys.stderr)
        sys.exit(1)
    cmd = stage.get("command", "")
    args = stage.get("args", [])
    if not isinstance(cmd, str) or not cmd:
        print(f"ERROR: stages_json[{idx}].command must be a non-empty string",
              file=sys.stderr)
        sys.exit(1)
    if not CMD_CHARSET_RE.match(cmd):
        print(f"ERROR: stages_json[{idx}].command contains unsupported characters: {cmd}",
              file=sys.stderr)
        sys.exit(1)
    if cmd not in PIPELINE_ALLOWLIST:
        print(f"ERROR: stages_json[{idx}].command is not in pipeline allowlist: {cmd}",
              file=sys.stderr)
        sys.exit(1)
    if not isinstance(args, list):
        print(f"ERROR: stages_json[{idx}].args must be an array", file=sys.stderr)
        sys.exit(1)
    if len(args) > max_ap:
        print(f"ERROR: stages_json[{idx}].args too long. max={max_ap}", file=sys.stderr)
        sys.exit(1)
    for ai, arg in enumerate(args):
        if not isinstance(arg, str):
            print(f"ERROR: stages_json[{idx}].args[{ai}] must be a string",
                  file=sys.stderr)
            sys.exit(1)
        if "\x00" in arg:
            print(f"ERROR: stages_json[{idx}].args[{ai}] contains NUL byte",
                  file=sys.stderr)
            sys.exit(1)
        if arg == ".." or arg.startswith("../") or "/../" in arg or arg.startswith("~"):
            print(f"ERROR: path traversal or home expansion argument is blocked: {arg}",
                  file=sys.stderr)
            sys.exit(1)
        if arg.startswith("/"):
            if not (arg == resolved_wd or arg.startswith(resolved_wd + "/")):
                print(
                    f"ERROR: absolute argument outside working_dir is blocked: {arg}",
                    file=sys.stderr,
                )
                sys.exit(1)
    print(json.dumps({"command": cmd, "args": args}))
PYEOF

# Read validated stages (one JSON object per line)
stages_data=()
while IFS= read -r line; do
    [[ -n "$line" ]] && stages_data+=("$line")
done < "$parsed_stages_file"
stages_count="${#stages_data[@]}"

# --- risky_pipeline placeholder ---
# Pipeline allowlist already excludes all high-risk commands (rm, mv, dd, etc.).
# This flag is retained for audit records and future extensibility.
risky_pipeline="false"

# --- default_approvals processing (mirrors execute.sh) ---
default_approvals_enabled="false"
if [[ -n "$default_approvals_raw" ]]; then
    normalized_default_approvals="$(printf '%s' "$default_approvals_raw" | tr '[:upper:]' '[:lower:]')"
    case "$normalized_default_approvals" in
        1|true)  default_approvals_enabled="true" ;;
        0|false) default_approvals_enabled="false" ;;
        *)
            printf 'ERROR: default approvals env must be one of [1, true, 0, false].\n' >&2
            exit 1
            ;;
    esac
fi

auth_required="true"
if [[ "$default_approvals_enabled" == "true" && "$risky_pipeline" != "true" ]]; then
    auth_required="false"
fi

# --- auth_context_digest ---
auth_context_digest="$(python3 - "$stages_json" "$resolved_working_dir" "$risky_pipeline" <<'PYEOF'
import hashlib
import json
import sys

context = {
    "risky": sys.argv[3] == "true",
    "stages_json": sys.argv[1],
    "working_dir": sys.argv[2],
}
print(hashlib.sha256(
    json.dumps(context, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest())
PYEOF
)"

# --- auth_expires_at_ms ---
auth_expires_at_ms="$(python3 - "$auth_prompt_timeout_ms" <<'PYEOF'
import time
import sys

print(int(time.time() * 1000) + int(sys.argv[1]))
PYEOF
)"

# --- Auth state initialisation ---
auth_mode="none"
auth_verified="true"
auth_ticket_id=""
auth_ticket_status="not_used"
auth_reason_code="AUTH_NOT_REQUIRED"
auth_source="none"
current_kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
current_arch="$(uname -m 2>/dev/null || echo unknown)"

# --- Stage 3: Authorization flow (mirrors execute.sh auth paths) ---
if [[ "$auth_required" == "true" ]]; then
    if [[ "$confirm_action" == "true" ]]; then
        auth_mode="confirm_action"
        auth_reason_code="AUTH_CONFIRM_ACTION_OK"
        auth_source="confirm_action"
    else
        auth_mode="prompt"
        auth_verified="false"
        wkwebview_auth_script="$(cd "$(dirname "$0")" && pwd)/run_safe_command__auth_wkwebview.sh"

        if [[ "$current_kernel" == "darwin" && "$current_arch" == "arm64" && -x "$wkwebview_auth_script" ]]; then
            set +e
            bash "$wkwebview_auth_script" \
                "$request_id" "<pipeline>" "$stages_json" \
                "$resolved_working_dir" "$auth_context_digest" "$auth_expires_at_ms" \
                >/dev/null 2>&1
            wk_prompt_exit=$?
            set -e
            if [[ "$wk_prompt_exit" -eq 0 ]]; then
                confirm_action="true"
                auth_verified="true"
                auth_reason_code="AUTH_PROMPT_APPROVED"
                auth_ticket_status="approved"
                auth_source="wkwebview"
            elif [[ "$wk_prompt_exit" -eq 10 ]]; then
                auth_reason_code="AUTH_PROMPT_DENIED"
                auth_ticket_status="denied"
                auth_source="wkwebview"
                printf 'ERROR: pipeline authorization denied. reason_code=%s\n' "$auth_reason_code" >&2
                exit 1
            elif [[ "$wk_prompt_exit" -eq 11 ]]; then
                auth_reason_code="AUTH_PROMPT_TIMEOUT"
                auth_ticket_status="expired"
                auth_source="wkwebview"
                printf 'ERROR: pipeline authorization timed out. reason_code=%s\n' "$auth_reason_code" >&2
                exit 1
            fi
        fi

        if [[ "$auth_verified" != "true" ]]; then
            if [[ "$current_kernel" == "darwin" ]] && command -v osascript >/dev/null 2>&1; then
                prompt_secs=$((auth_prompt_timeout_ms / 1000))
                pipeline_summary="$(python3 - "$stages_json" <<'PYEOF'
import json
import sys

try:
    stages = json.loads(sys.argv[1])
    print(" | ".join(s["command"] for s in stages if isinstance(s, dict)))
except Exception:
    print("<pipeline>")
PYEOF
)"
                prompt_message="$(printf \
                    'Authorize Pipeline Execution\n\nPipeline: %s\nWorking Dir: %s\nContext Digest: %s\n\nExpires in %ss' \
                    "$pipeline_summary" "$resolved_working_dir" "$auth_context_digest" "$prompt_secs")"
                prompt_result="$(osascript - "$prompt_message" "$prompt_secs" 2>/dev/null <<'APPLESCRIPT' || true
on run argv
    set promptMessage to item 1 of argv
    set promptSecs to (item 2 of argv) as integer
    display dialog promptMessage buttons {"Deny", "Authorize"} default button "Authorize" giving up after promptSecs with title "run_safe_command__pipeline Authorization"
end run
APPLESCRIPT
)"
                if [[ "$prompt_result" == *"button returned:Authorize"* ]]; then
                    confirm_action="true"
                    auth_verified="true"
                    auth_reason_code="AUTH_PROMPT_APPROVED"
                    auth_ticket_status="approved"
                    auth_source="osa"
                elif [[ "$prompt_result" == *"gave up:true"* ]]; then
                    auth_reason_code="AUTH_PROMPT_TIMEOUT"
                    auth_ticket_status="expired"
                    auth_source="osa"
                    printf 'ERROR: pipeline authorization timed out. reason_code=%s\n' "$auth_reason_code" >&2
                    exit 1
                else
                    auth_reason_code="AUTH_PROMPT_DENIED"
                    auth_ticket_status="denied"
                    auth_source="osa"
                    printf 'ERROR: pipeline authorization denied. reason_code=%s\n' "$auth_reason_code" >&2
                    exit 1
                fi
            else
                auth_reason_code="AUTH_CONFIRM_ACTION_REQUIRED"
                auth_ticket_status="not_used"
                auth_source="confirm_action"
                printf 'ERROR: pipeline requires authorization; set confirm_action=true. reason_code=%s\n' \
                    "$auth_reason_code" >&2
                exit 1
            fi
        fi
    fi
else
    auth_reason_code="AUTH_NOT_REQUIRED_DEFAULT_APPROVALS"
    auth_source="default_approvals"
fi

# --- Stage 4: Execution timing start ---
started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
start_epoch="$(python3 - <<'PYEOF'
import time
print(int(time.time() * 1000))
PYEOF
)"

# Export stages and resolved working_dir for the subprocess Python block
export SAFE_PIPELINE_STAGES_JSON="$stages_json"
export SAFE_PIPELINE_WORKING_DIR="$resolved_working_dir"

set +e
python3 - <<'PYEOF' > "$stdout_file" 2> "$stderr_file"
import json
import os
import subprocess
import sys

stages_json = os.environ["SAFE_PIPELINE_STAGES_JSON"]
working_dir = os.environ["SAFE_PIPELINE_WORKING_DIR"]

try:
    stages = json.loads(stages_json)
except json.JSONDecodeError as exc:
    print(f"ERROR: failed to parse stages_json: {exc}", file=sys.stderr)
    sys.exit(1)

# Build subprocess Popen chain — user data is always in the args array,
# never interpolated into a shell command string.
procs = []
for idx, stage in enumerate(stages):
    cmd = stage["command"]
    args = stage.get("args", [])
    stdin_pipe = procs[-1].stdout if procs else None
    try:
        proc = subprocess.Popen(
            [cmd, *args],
            stdin=stdin_pipe,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=working_dir,
        )
    except FileNotFoundError:
        # Close previous pipe handles to avoid deadlock before exiting
        for p in procs:
            try:
                p.stdout.close()
            except Exception:  # noqa: BLE001
                pass
        print(f"ERROR: command not found: {cmd}", file=sys.stderr)
        sys.exit(127)
    # Close the write-end of the previous pipe now that the next proc has it
    if procs:
        procs[-1].stdout.close()
    procs.append(proc)

# Collect output: last process provides final stdout; all provide stderr
all_stderr = []
last_stdout = b""
last_exit_code = 0

for idx, proc in enumerate(procs):
    if idx == len(procs) - 1:
        stdout_bytes, stderr_bytes = proc.communicate()
        last_stdout = stdout_bytes
    else:
        _, stderr_bytes = proc.communicate()
    if stderr_bytes:
        all_stderr.append(
            f"[stage {idx}] {stderr_bytes.decode('utf-8', errors='replace').rstrip()}"
        )
    last_exit_code = proc.returncode

sys.stdout.buffer.write(last_stdout)
if all_stderr:
    print("\n".join(all_stderr), file=sys.stderr)

sys.exit(last_exit_code)
PYEOF
cmd_exit_code=$?
set -e

# --- Duration calculation ---
end_epoch="$(python3 - <<'PYEOF'
import time
print(int(time.time() * 1000))
PYEOF
)"
duration_ms=$((end_epoch - start_epoch))

# --- Export variables for response renderer ---
export SAFE_PIPELINE_STAGES_COUNT="$stages_count"
export SAFE_PIPELINE_CONFIRM_ACTION="$confirm_action"
export SAFE_PIPELINE_REQUEST_ID="$request_id"
export SAFE_PIPELINE_RISKY_PIPELINE="$risky_pipeline"
export SAFE_PIPELINE_AUTH_MODE="$auth_mode"
export SAFE_PIPELINE_AUTH_VERIFIED="$auth_verified"
export SAFE_PIPELINE_AUTH_REQUIRED="$auth_required"
export SAFE_PIPELINE_AUTH_TICKET_ID="$auth_ticket_id"
export SAFE_PIPELINE_AUTH_TICKET_STATUS="$auth_ticket_status"
export SAFE_PIPELINE_AUTH_REASON_CODE="$auth_reason_code"
export SAFE_PIPELINE_AUTH_CONTEXT_DIGEST="$auth_context_digest"
export SAFE_PIPELINE_AUTH_SOURCE="$auth_source"
export SAFE_PIPELINE_STARTED_AT="$started_at"
export SAFE_PIPELINE_EXIT_CODE="$cmd_exit_code"
export SAFE_PIPELINE_DURATION_MS="$duration_ms"
export SAFE_PIPELINE_KERNEL="$current_kernel"
export SAFE_PIPELINE_ARCH="$current_arch"
export SAFE_PIPELINE_AUDIT_FILE="$audit_file"
export SAFE_PIPELINE_OUTPUT_MODE="$execute_output_mode"
export SAFE_PIPELINE_AUDIT_ROTATE_MAX_BYTES="$audit_rotate_max_bytes"
export SAFE_PIPELINE_AUDIT_ROTATE_MAX_FILES="$audit_rotate_max_files"
export SAFE_PIPELINE_AUDIT_ROTATE_DAILY="$audit_rotate_daily"
export SAFE_PIPELINE_WARNINGS_FILE="$warnings_file"
export SAFE_PIPELINE_STDOUT_FILE="$stdout_file"
export SAFE_PIPELINE_STDERR_FILE="$stderr_file"

# --- Stage 5: Response rendering + Audit write ---
python3 - <<'PYEOF'
import datetime
import hashlib
import json
import os
import pathlib
import uuid


def read_text(path: str) -> str:
    p = pathlib.Path(path)
    if not p.exists():
        return ""
    return p.read_text(encoding="utf-8", errors="replace")


stages_json = os.environ["SAFE_PIPELINE_STAGES_JSON"]
working_dir = os.environ["SAFE_PIPELINE_WORKING_DIR"]
confirm_action = os.environ["SAFE_PIPELINE_CONFIRM_ACTION"]
request_id = os.environ.get("SAFE_PIPELINE_REQUEST_ID", "")
risky_pipeline = os.environ["SAFE_PIPELINE_RISKY_PIPELINE"] == "true"
started_at = os.environ["SAFE_PIPELINE_STARTED_AT"]
exit_code = int(os.environ["SAFE_PIPELINE_EXIT_CODE"])
duration_ms = int(os.environ["SAFE_PIPELINE_DURATION_MS"])
kernel = os.environ["SAFE_PIPELINE_KERNEL"]
arch = os.environ["SAFE_PIPELINE_ARCH"]
audit_file = os.environ["SAFE_PIPELINE_AUDIT_FILE"]
auth_mode = os.environ.get("SAFE_PIPELINE_AUTH_MODE", "none")
auth_verified = os.environ.get("SAFE_PIPELINE_AUTH_VERIFIED", "true") == "true"
auth_required = os.environ.get("SAFE_PIPELINE_AUTH_REQUIRED", "true") == "true"
auth_ticket_id = os.environ.get("SAFE_PIPELINE_AUTH_TICKET_ID", "")
auth_ticket_status = os.environ.get("SAFE_PIPELINE_AUTH_TICKET_STATUS", "not_used")
auth_reason_code = os.environ.get("SAFE_PIPELINE_AUTH_REASON_CODE", "AUTH_NOT_REQUIRED")
auth_context_digest = os.environ.get("SAFE_PIPELINE_AUTH_CONTEXT_DIGEST", "")
auth_source = os.environ.get("SAFE_PIPELINE_AUTH_SOURCE", "none")
output_mode = os.environ.get("SAFE_PIPELINE_OUTPUT_MODE", "concise").strip().lower()
if output_mode not in {"concise", "full"}:
    output_mode = "concise"
audit_rotate_max_bytes = int(os.environ.get("SAFE_PIPELINE_AUDIT_ROTATE_MAX_BYTES", "1048576"))
audit_rotate_max_files = int(os.environ.get("SAFE_PIPELINE_AUDIT_ROTATE_MAX_FILES", "10"))
audit_rotate_daily = os.environ.get("SAFE_PIPELINE_AUDIT_ROTATE_DAILY", "false") == "true"

warnings_text = read_text(os.environ["SAFE_PIPELINE_WARNINGS_FILE"]).strip()
stdout_text = read_text(os.environ["SAFE_PIPELINE_STDOUT_FILE"])
stderr_text = read_text(os.environ["SAFE_PIPELINE_STDERR_FILE"])

try:
    parsed_stages = json.loads(stages_json)
except json.JSONDecodeError:
    parsed_stages = []

stages_count = len(parsed_stages) if isinstance(parsed_stages, list) else 0
pipeline_label = "<pipeline: " + "|".join(
    s.get("command", "?") for s in parsed_stages if isinstance(s, dict)
) + ">"

if not auth_context_digest:
    context_for_digest = {
        "risky": risky_pipeline,
        "stages_json": stages_json,
        "working_dir": working_dir,
    }
    auth_context_digest = hashlib.sha256(
        json.dumps(
            context_for_digest, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
    ).hexdigest()

warnings = [line for line in warnings_text.splitlines() if line]
status = "success" if exit_code == 0 else "error"

record_id = request_id or f"run-pipeline-{uuid.uuid4()}"
completed_at = (
    datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
)

response = {
    "request": {
        "request_id": request_id,
        "command": pipeline_label,
        "stages": parsed_stages,
        "stages_count": stages_count,
        "working_dir": working_dir,
        "confirm_action": confirm_action == "true",
    },
    "security": {
        "risky_pipeline": risky_pipeline,
        "allowlist_source": "pipeline_v1",
        "confirm_action_satisfied": auth_verified if auth_required else True,
        "guardrails": [
            "pipeline-command-allowlist",
            "stages-args-validated",
            "working-directory-validated",
            "python-subprocess-chain-no-shell-eval",
        ],
        "warnings": warnings,
    },
    "authorization": {
        "mode": auth_mode,
        "ticket_id": auth_ticket_id,
        "ticket_status": auth_ticket_status,
        "verified": auth_verified,
        "reason_code": auth_reason_code,
        "context_digest": auth_context_digest,
        "source": auth_source,
    },
    "execution": {
        "status": status,
        "exit_code": exit_code,
        "duration_ms": duration_ms,
        "started_at": started_at,
        "completed_at": completed_at,
        "kernel": kernel,
        "arch": arch,
        "stdout": stdout_text,
        "stderr": stderr_text,
    },
    "audit": {
        "record_id": record_id,
        "file": audit_file,
        "written": False,
        "rotation_applied": False,
        "rotated_files": [],
    },
    # Top-level standard fields required by lint output schema
    "status": status,
    "exit_code": exit_code,
    "stdout": stdout_text,
    "stderr": stderr_text,
    "command": pipeline_label,
    "execution_time_ms": duration_ms,
}

audit_payload = {
    "record_id": record_id,
    "ts": completed_at,
    "request": {
        "command": "<pipeline>",
        "stages": parsed_stages,
        "stages_count": stages_count,
        "working_dir": working_dir,
    },
    "security": {
        "risky_pipeline": risky_pipeline,
        "confirm_action_satisfied": response["security"]["confirm_action_satisfied"],
        "warnings": warnings,
    },
    "authorization": {
        "mode": auth_mode,
        "ticket_id": auth_ticket_id,
        "ticket_status": auth_ticket_status,
        "verified": auth_verified,
        "reason_code": auth_reason_code,
        "source": auth_source,
    },
    "execution": {
        "status": status,
        "exit_code": exit_code,
        "duration_ms": duration_ms,
        "kernel": kernel,
        "arch": arch,
    },
}


def rotation_candidates(base_file: pathlib.Path) -> list[pathlib.Path]:
    pattern = f"{base_file.name}." + "*.ndjson"
    return sorted(
        base_file.parent.glob(pattern),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )


def rotate_if_needed(base_file: pathlib.Path) -> tuple[bool, list[str]]:
    if not base_file.exists():
        return False, []
    now = datetime.datetime.now(datetime.timezone.utc)
    stat = base_file.stat()
    rotate_by_size = stat.st_size >= audit_rotate_max_bytes
    rotate_by_day = False
    if audit_rotate_daily:
        modified_day = datetime.datetime.fromtimestamp(
            stat.st_mtime, tz=datetime.timezone.utc
        ).date()
        rotate_by_day = modified_day != now.date()
    if not rotate_by_size and not rotate_by_day:
        return False, []
    suffix = now.strftime("%Y%m%d-%H%M%S")
    rotated_path = base_file.with_name(f"{base_file.name}.{suffix}.ndjson")
    index = 1
    while rotated_path.exists():
        rotated_path = base_file.with_name(
            f"{base_file.name}.{suffix}.{index}.ndjson"
        )
        index += 1
    base_file.rename(rotated_path)
    rotated = [str(rotated_path)]
    candidates = rotation_candidates(base_file)
    for stale in candidates[audit_rotate_max_files:]:
        try:
            stale.unlink()
            rotated.append(str(stale))
        except OSError:
            continue
    return True, rotated


def render_response(full_response: dict) -> dict:
    if output_mode == "full":
        return full_response
    auth = full_response.get("authorization", {})
    audit = full_response.get("audit", {})
    return {
        "status": full_response.get("status"),
        "exit_code": full_response.get("exit_code"),
        "stdout": full_response.get("stdout", ""),
        "stderr": full_response.get("stderr", ""),
        "command": full_response.get("command", ""),
        "execution_time_ms": full_response.get("execution_time_ms", 0),
        "stages_count": full_response.get("request", {}).get("stages_count", 0),
        "authorization": {
            "verified": auth.get("verified"),
            "reason_code": auth.get("reason_code"),
            "source": auth.get("source"),
        },
        "audit": {
            "record_id": audit.get("record_id"),
            "written": audit.get("written", False),
        },
    }


try:
    audit_path = pathlib.Path(audit_file)
    audit_path.parent.mkdir(parents=True, exist_ok=True)
    rotation_applied, rotated_files = rotate_if_needed(audit_path)
    response["audit"]["rotation_applied"] = rotation_applied
    response["audit"]["rotated_files"] = rotated_files
    with audit_path.open("a", encoding="utf-8") as fp:
        fp.write(json.dumps(audit_payload, ensure_ascii=True) + "\n")
    response["audit"]["written"] = True
except OSError as exc:
    response["audit"]["error"] = f"failed to append audit record: {exc}"

print(json.dumps(render_response(response), ensure_ascii=True))
PYEOF

exit "$cmd_exit_code"
