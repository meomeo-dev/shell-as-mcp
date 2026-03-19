#!/usr/bin/env bash
set -euo pipefail

command_name="${TOOL_COMMAND:?TOOL_COMMAND environment variable is required}"
args_json="${TOOL_ARGS_JSON:?TOOL_ARGS_JSON environment variable is required}"
working_dir="${TOOL_WORKING_DIR:?TOOL_WORKING_DIR environment variable is required}"
confirm_action="${TOOL_CONFIRM_ACTION:-false}"
request_id="${TOOL_REQUEST_ID:-}"
auth_ticket_id=""
default_approvals_raw="${TOOL_DEFAULT_APPROVALS:-${DEFAULT_APPROVALS:-}}"
auth_prompt_timeout_ms="${TOOL_AUTH_PROMPT_TIMEOUT_MS:-45000}"
enable_trace="${TOOL_ENABLE_TRACE:-true}"
trace_mode="${TOOL_TRACE_MODE:-auto}"
enable_explanation="${TOOL_ENABLE_EXPLANATION:-true}"
explain_provider="${TOOL_EXPLAIN_PROVIDER:-local}"
explain_timeout_ms="${TOOL_EXPLAIN_TIMEOUT_MS:-1200}"
execute_output_mode_raw="${TOOL_EXECUTE_OUTPUT_MODE:-concise}"
max_arg_count="${TOOL_MAX_ARG_COUNT:-64}"
audit_file="${TOOL_AUDIT_FILE:-${TMPDIR:-/tmp}/mcp-shell-run-safe-command-audit.ndjson}"
audit_rotate_max_bytes="${TOOL_AUDIT_ROTATE_MAX_BYTES:-1048576}"
audit_rotate_max_files="${TOOL_AUDIT_ROTATE_MAX_FILES:-10}"
audit_rotate_daily="${TOOL_AUDIT_ROTATE_DAILY:-false}"

execute_output_mode="$(printf '%s' "$execute_output_mode_raw" | tr '[:upper:]' '[:lower:]')"
execute_output_mode_invalid_value=""
if [[ "$execute_output_mode" != "concise" && "$execute_output_mode" != "full" ]]; then
    execute_output_mode_invalid_value="$execute_output_mode_raw"
    execute_output_mode="concise"
fi

if ! [[ "$command_name" =~ ^[a-zA-Z0-9._+:-]+$ ]]; then
  printf 'ERROR: command contains unsupported characters: %s\n' "$command_name" >&2
  exit 1
fi

if ! [[ "$max_arg_count" =~ ^[0-9]+$ ]] || [[ "$max_arg_count" -lt 1 ]] || [[ "$max_arg_count" -gt 512 ]]; then
  printf 'ERROR: TOOL_MAX_ARG_COUNT must be an integer in range [1, 512].\n' >&2
  exit 1
fi

if [[ "$enable_trace" != "true" && "$enable_trace" != "false" ]]; then
    printf 'ERROR: TOOL_ENABLE_TRACE must be true or false.\n' >&2
    exit 1
fi

if [[ -n "$trace_mode" ]]; then
    if [[ "$trace_mode" != "none" && "$trace_mode" != "auto" && "$trace_mode" != "strace" && "$trace_mode" != "dtruss" ]]; then
        printf 'ERROR: TOOL_TRACE_MODE must be one of: none, auto, strace, dtruss.\n' >&2
        exit 1
    fi
fi

if [[ "$enable_explanation" != "true" && "$enable_explanation" != "false" ]]; then
    printf 'ERROR: TOOL_ENABLE_EXPLANATION must be true or false.\n' >&2
    exit 1
fi

if [[ "$explain_provider" != "none" && "$explain_provider" != "local" && "$explain_provider" != "explainshell" ]]; then
    printf 'ERROR: TOOL_EXPLAIN_PROVIDER must be one of: none, local, explainshell.\n' >&2
    exit 1
fi

if ! [[ "$explain_timeout_ms" =~ ^[0-9]+$ ]] || [[ "$explain_timeout_ms" -lt 100 ]] || [[ "$explain_timeout_ms" -gt 3000 ]]; then
    printf 'ERROR: TOOL_EXPLAIN_TIMEOUT_MS must be an integer in range [100, 3000].\n' >&2
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

if ! [[ "$auth_prompt_timeout_ms" =~ ^[0-9]+$ ]] || [[ "$auth_prompt_timeout_ms" -lt 5000 ]] || [[ "$auth_prompt_timeout_ms" -gt 120000 ]]; then
    printf 'ERROR: TOOL_AUTH_PROMPT_TIMEOUT_MS must be an integer in range [5000, 120000].\n' >&2
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
  printf 'ERROR: python3 is required for args_json parsing and JSON response rendering.\n' >&2
  exit 1
fi

if ! executable_path="$(command -v "$command_name" 2>/dev/null)"; then
  printf 'ERROR: command not found: %s\n' "$command_name" >&2
  exit 1
fi

risky_command="false"
if [[ "$command_name" =~ ^(rm|mv|dd|chmod|chown|kill|pkill|killall|shutdown|reboot|launchctl)$ ]]; then
  risky_command="true"
fi

default_approvals_enabled="false"
if [[ -n "$default_approvals_raw" ]]; then
    normalized_default_approvals="$(printf '%s' "$default_approvals_raw" | tr '[:upper:]' '[:lower:]')"
    case "$normalized_default_approvals" in
        1|true)
            default_approvals_enabled="true"
            ;;
        0|false)
            default_approvals_enabled="false"
            ;;
        *)
            printf 'ERROR: default approvals env must be one of [1, true, 0, false].\n' >&2
            exit 1
            ;;
    esac
fi

auth_required="true"
if [[ "$default_approvals_enabled" == "true" && "$risky_command" != "true" ]]; then
    auth_required="false"
fi

if [[ -z "$trace_mode" ]]; then
    if [[ "$enable_trace" == "true" ]]; then
        trace_mode="auto"
    else
        trace_mode="none"
    fi
fi

auth_mode="none"
auth_verified="true"
auth_ticket_status="not_used"
auth_reason_code="AUTH_NOT_REQUIRED"
auth_context_digest=""
auth_source="none"

parsed_args_file="$(mktemp)"
warnings_file="$(mktemp)"
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
trace_file=""
trap 'rm -f "${parsed_args_file:-}" "${warnings_file:-}" "${stdout_file:-}" "${stderr_file:-}" "${trace_file:-}"' EXIT

if [[ -n "$execute_output_mode_invalid_value" ]]; then
    printf 'invalid output mode: %s; fallback=concise\n' "$execute_output_mode_invalid_value" >> "$warnings_file"
fi

python3 - "$args_json" "$max_arg_count" <<'PYEOF' > "$parsed_args_file"
import json
import sys

args_raw = sys.argv[1]
max_count = int(sys.argv[2])

try:
    value = json.loads(args_raw)
except json.JSONDecodeError as exc:
    print(f"ERROR: args_json must be valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(value, list):
    print("ERROR: args_json must be a JSON array", file=sys.stderr)
    sys.exit(1)

if len(value) > max_count:
    print(f"ERROR: args_json too long. max={max_count}", file=sys.stderr)
    sys.exit(1)

for index, item in enumerate(value):
    if not isinstance(item, str):
        print(f"ERROR: args_json[{index}] must be a string", file=sys.stderr)
        sys.exit(1)
    if "\x00" in item:
        print(f"ERROR: args_json[{index}] contains NUL byte", file=sys.stderr)
        sys.exit(1)
    print(item)
PYEOF

parsed_args=()
while IFS= read -r arg_line; do
    parsed_args+=("$arg_line")
done < "$parsed_args_file"

current_kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
current_arch="$(uname -m 2>/dev/null || echo unknown)"

for arg in "${parsed_args[@]}"; do
    if [[ "$arg" == ".." || "$arg" == ../* || "$arg" == */../* || "$arg" == ~* ]]; then
        printf 'ERROR: path traversal or home expansion argument is blocked: %s\n' "$arg" >&2
        exit 1
    fi
    if [[ "$arg" == /* ]]; then
        case "$arg" in
            "$resolved_working_dir"|"$resolved_working_dir"/*)
                ;;
            *)
                printf 'ERROR: absolute argument outside working_dir is blocked: %s\n' "$arg" >&2
                exit 1
                ;;
        esac
  fi
done

auth_context_digest="$(python3 - "$command_name" "$args_json" "$resolved_working_dir" "$risky_command" <<'PYEOF'
import hashlib
import json
import sys

context = {
    "args_json": sys.argv[2],
    "command": sys.argv[1],
    "risky": sys.argv[4] == "true",
    "working_dir": sys.argv[3],
}
print(hashlib.sha256(json.dumps(context, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest())
PYEOF
)"

auth_expires_at_ms="$(python3 - "$auth_prompt_timeout_ms" <<'PYEOF'
import time
import sys

timeout_ms = int(sys.argv[1])
print(int(time.time() * 1000) + timeout_ms)
PYEOF
)"

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
            bash "$wkwebview_auth_script" "$request_id" "$command_name" "$args_json" "$resolved_working_dir" "$auth_context_digest" "$auth_expires_at_ms" >/dev/null 2>&1
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
                printf 'ERROR: command authorization denied. reason_code=%s\n' "$auth_reason_code" >&2
                exit 1
            elif [[ "$wk_prompt_exit" -eq 11 ]]; then
                auth_reason_code="AUTH_PROMPT_TIMEOUT"
                auth_ticket_status="expired"
                auth_source="wkwebview"
                printf 'ERROR: command authorization timed out. reason_code=%s\n' "$auth_reason_code" >&2
                exit 1
            fi
        fi

        if [[ "$auth_verified" != "true" ]]; then
            if [[ "$current_kernel" == "darwin" ]] && command -v osascript >/dev/null 2>&1; then
                prompt_secs=$((auth_prompt_timeout_ms / 1000))
                prompt_message="$(printf 'Risk: HIGH\nAuthorize Risky Command Execution\n\nCommand: %s\nArgs: %s\nWorking Dir: %s\nContext Digest: %s\n\nExpires in %ss' "$command_name" "$args_json" "$resolved_working_dir" "$auth_context_digest" "$prompt_secs")"
                prompt_result="$(osascript - "$prompt_message" "$prompt_secs" 2>/dev/null <<'APPLESCRIPT' || true
on run argv
        set promptMessage to item 1 of argv
        set promptSecs to (item 2 of argv) as integer
        display dialog promptMessage buttons {"Deny", "Authorize"} default button "Authorize" giving up after promptSecs with title "run_safe_command Authorization"
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
                    printf 'ERROR: command authorization timed out. reason_code=%s\n' "$auth_reason_code" >&2
                    exit 1
                else
                    auth_reason_code="AUTH_PROMPT_DENIED"
                    auth_ticket_status="denied"
                    auth_source="osa"
                    printf 'ERROR: command authorization denied. reason_code=%s\n' "$auth_reason_code" >&2
                    exit 1
                fi
            else
                auth_reason_code="AUTH_CONFIRM_ACTION_REQUIRED"
                auth_ticket_status="not_used"
                auth_source="confirm_action"
                printf 'ERROR: command requires authorization and no local prompt is available; set confirm_action=true. reason_code=%s\n' "$auth_reason_code" >&2
                exit 1
            fi
        fi
    fi
else
    auth_reason_code="AUTH_NOT_REQUIRED_DEFAULT_APPROVALS"
    auth_source="default_approvals"
fi

if ! command -v strace >/dev/null 2>&1; then
  printf 'optional trace backend unavailable: strace not found on %s\n' "$current_kernel" >> "$warnings_file"
fi

started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
start_epoch="$(python3 - <<'PYEOF'
import time
print(int(time.time() * 1000))
PYEOF
)"

set +e
trace_requested="false"
trace_collector="none"
trace_supported="false"
trace_effective_mode="none"
trace_downgrade_reason_code=""
trace_file="$(mktemp)"
if [[ "$trace_mode" != "none" ]]; then
    trace_requested="true"
    if [[ ( "$trace_mode" == "auto" || "$trace_mode" == "strace" ) && "$current_kernel" == "linux" ]] && command -v strace >/dev/null 2>&1; then
        trace_collector="strace"
        trace_supported="true"
        trace_effective_mode="strace"
        (
            cd "$resolved_working_dir"
            strace -f -o "$trace_file" "$command_name" "${parsed_args[@]}"
        ) >"$stdout_file" 2>"$stderr_file"
        cmd_exit_code=$?
    elif [[ "$current_kernel" == "darwin" ]]; then
        if [[ "$trace_mode" != "strace" ]] && command -v dtruss >/dev/null 2>&1; then
            if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
                trace_collector="dtruss"
                trace_supported="true"
                trace_effective_mode="dtruss"
                (
                    cd "$resolved_working_dir"
                    dtruss -f -o "$trace_file" "$command_name" "${parsed_args[@]}"
                ) >"$stdout_file" 2>"$stderr_file"
                cmd_exit_code=$?
                if [[ "$cmd_exit_code" -ne 0 ]]; then
                    printf 'trace backend dtruss failed; falling back to plain execution. reason_code=TRACE_BACKEND_FAILED\n' >> "$warnings_file"
                    trace_downgrade_reason_code="TRACE_BACKEND_FAILED"
                    trace_collector="none"
                    trace_supported="false"
                    trace_effective_mode="none"
                    (
                        cd "$resolved_working_dir"
                        "$command_name" "${parsed_args[@]}"
                    ) >"$stdout_file" 2>"$stderr_file"
                    cmd_exit_code=$?
                fi
            else
                trace_downgrade_reason_code="TRACE_DARWIN_PRIVILEGE_REQUIRED"
                printf 'trace backend downgrade: dtruss requires elevated privilege. reason_code=%s\n' "$trace_downgrade_reason_code" >> "$warnings_file"
                (
                    cd "$resolved_working_dir"
                    "$command_name" "${parsed_args[@]}"
                ) >"$stdout_file" 2>"$stderr_file"
                cmd_exit_code=$?
            fi
        else
            trace_downgrade_reason_code="TRACE_BACKEND_NOT_FOUND"
            printf 'optional trace backend unavailable on darwin. reason_code=%s\n' "$trace_downgrade_reason_code" >> "$warnings_file"
            (
                cd "$resolved_working_dir"
                "$command_name" "${parsed_args[@]}"
            ) >"$stdout_file" 2>"$stderr_file"
            cmd_exit_code=$?
        fi
    elif [[ "$trace_mode" == "strace" ]] && ! command -v strace >/dev/null 2>&1; then
        trace_downgrade_reason_code="TRACE_BACKEND_NOT_FOUND"
        printf 'optional trace backend unavailable: strace not found. reason_code=%s\n' "$trace_downgrade_reason_code" >> "$warnings_file"
        (
            cd "$resolved_working_dir"
            "$command_name" "${parsed_args[@]}"
        ) >"$stdout_file" 2>"$stderr_file"
        cmd_exit_code=$?
    else
        if [[ "$trace_mode" == "dtruss" || "$trace_mode" == "strace" ]]; then
            trace_downgrade_reason_code="TRACE_BACKEND_UNSUPPORTED"
            printf 'requested trace mode unsupported on kernel=%s. reason_code=%s\n' "$current_kernel" "$trace_downgrade_reason_code" >> "$warnings_file"
        fi
        (
            cd "$resolved_working_dir"
            "$command_name" "${parsed_args[@]}"
        ) >"$stdout_file" 2>"$stderr_file"
        cmd_exit_code=$?
    fi
else
    (
        cd "$resolved_working_dir"
        "$command_name" "${parsed_args[@]}"
    ) >"$stdout_file" 2>"$stderr_file"
    cmd_exit_code=$?
fi
set -e

end_epoch="$(python3 - <<'PYEOF'
import time
print(int(time.time() * 1000))
PYEOF
)"
duration_ms=$((end_epoch - start_epoch))

export SAFE_CMD_COMMAND_NAME="$command_name"
export SAFE_CMD_ARGS_JSON="$args_json"
export SAFE_CMD_WORKING_DIR="$working_dir"
export SAFE_CMD_RESOLVED_WORKING_DIR="$resolved_working_dir"
export SAFE_CMD_CONFIRM_ACTION="$confirm_action"
export SAFE_CMD_REQUEST_ID="$request_id"
export SAFE_CMD_RISKY_COMMAND="$risky_command"
export SAFE_CMD_COMMAND_ALLOWED="true"
export SAFE_CMD_AUTH_MODE="$auth_mode"
export SAFE_CMD_AUTH_VERIFIED="$auth_verified"
export SAFE_CMD_AUTH_REQUIRED="$auth_required"
export SAFE_CMD_AUTH_TICKET_ID="$auth_ticket_id"
export SAFE_CMD_AUTH_TICKET_STATUS="$auth_ticket_status"
export SAFE_CMD_AUTH_REASON_CODE="$auth_reason_code"
export SAFE_CMD_AUTH_CONTEXT_DIGEST="$auth_context_digest"
export SAFE_CMD_AUTH_SOURCE="$auth_source"
export SAFE_CMD_EXECUTABLE_PATH="$executable_path"
export SAFE_CMD_STARTED_AT="$started_at"
export SAFE_CMD_EXIT_CODE="$cmd_exit_code"
export SAFE_CMD_DURATION_MS="$duration_ms"
export SAFE_CMD_KERNEL="$current_kernel"
export SAFE_CMD_ARCH="$current_arch"
export SAFE_CMD_AUDIT_FILE="$audit_file"
export SAFE_CMD_ENABLE_TRACE="$enable_trace"
export SAFE_CMD_TRACE_MODE_REQUESTED="$trace_mode"
export SAFE_CMD_ENABLE_EXPLANATION="$enable_explanation"
export SAFE_CMD_TRACE_REQUESTED="$trace_requested"
export SAFE_CMD_TRACE_COLLECTOR="$trace_collector"
export SAFE_CMD_TRACE_SUPPORTED="$trace_supported"
export SAFE_CMD_TRACE_EFFECTIVE_MODE="$trace_effective_mode"
export SAFE_CMD_TRACE_DOWNGRADE_REASON_CODE="$trace_downgrade_reason_code"
export SAFE_CMD_TRACE_FILE="$trace_file"
export SAFE_CMD_EXPLAIN_PROVIDER="$explain_provider"
export SAFE_CMD_EXPLAIN_TIMEOUT_MS="$explain_timeout_ms"
export SAFE_CMD_OUTPUT_MODE="$execute_output_mode"
export SAFE_CMD_AUDIT_ROTATE_MAX_BYTES="$audit_rotate_max_bytes"
export SAFE_CMD_AUDIT_ROTATE_MAX_FILES="$audit_rotate_max_files"
export SAFE_CMD_AUDIT_ROTATE_DAILY="$audit_rotate_daily"
export SAFE_CMD_WARNINGS_FILE="$warnings_file"
export SAFE_CMD_STDOUT_FILE="$stdout_file"
export SAFE_CMD_STDERR_FILE="$stderr_file"

python3 - <<'PYEOF'
import datetime
import hashlib
import json
import os
import pathlib
import subprocess
import time
import uuid


def read_text(path: str) -> str:
    p = pathlib.Path(path)
    if not p.exists():
        return ""
    return p.read_text(encoding="utf-8", errors="replace")


command_name = os.environ["SAFE_CMD_COMMAND_NAME"]
args_json = os.environ["SAFE_CMD_ARGS_JSON"]
working_dir = os.environ["SAFE_CMD_WORKING_DIR"]
resolved_working_dir = os.environ["SAFE_CMD_RESOLVED_WORKING_DIR"]
confirm_action = os.environ["SAFE_CMD_CONFIRM_ACTION"]
request_id = os.environ.get("SAFE_CMD_REQUEST_ID", "")
risky_command = os.environ["SAFE_CMD_RISKY_COMMAND"] == "true"
executable_path = os.environ["SAFE_CMD_EXECUTABLE_PATH"]
started_at = os.environ["SAFE_CMD_STARTED_AT"]
exit_code = int(os.environ["SAFE_CMD_EXIT_CODE"])
duration_ms = int(os.environ["SAFE_CMD_DURATION_MS"])
kernel = os.environ["SAFE_CMD_KERNEL"]
arch = os.environ["SAFE_CMD_ARCH"]
audit_file = os.environ["SAFE_CMD_AUDIT_FILE"]
enable_trace = os.environ["SAFE_CMD_ENABLE_TRACE"] == "true"
enable_explanation = os.environ["SAFE_CMD_ENABLE_EXPLANATION"] == "true"
trace_mode_requested = os.environ.get("SAFE_CMD_TRACE_MODE_REQUESTED", "none")
trace_requested = os.environ["SAFE_CMD_TRACE_REQUESTED"] == "true"
trace_collector = os.environ["SAFE_CMD_TRACE_COLLECTOR"]
trace_supported = os.environ["SAFE_CMD_TRACE_SUPPORTED"] == "true"
trace_effective_mode = os.environ.get("SAFE_CMD_TRACE_EFFECTIVE_MODE", "none")
trace_downgrade_reason_code = os.environ.get("SAFE_CMD_TRACE_DOWNGRADE_REASON_CODE", "")
trace_file = os.environ["SAFE_CMD_TRACE_FILE"]
auth_mode = os.environ.get("SAFE_CMD_AUTH_MODE", "none")
auth_verified = os.environ.get("SAFE_CMD_AUTH_VERIFIED", "true") == "true"
auth_required = os.environ.get("SAFE_CMD_AUTH_REQUIRED", "true") == "true"
auth_ticket_id = os.environ.get("SAFE_CMD_AUTH_TICKET_ID", "")
auth_ticket_status = os.environ.get("SAFE_CMD_AUTH_TICKET_STATUS", "not_used")
auth_reason_code = os.environ.get("SAFE_CMD_AUTH_REASON_CODE", "AUTH_NOT_REQUIRED")
auth_context_digest = os.environ.get("SAFE_CMD_AUTH_CONTEXT_DIGEST", "")
auth_source = os.environ.get("SAFE_CMD_AUTH_SOURCE", "none")
explain_provider_requested = os.environ.get("SAFE_CMD_EXPLAIN_PROVIDER", "local")
explain_timeout_ms = int(os.environ.get("SAFE_CMD_EXPLAIN_TIMEOUT_MS", "1200"))
output_mode = os.environ.get("SAFE_CMD_OUTPUT_MODE", "concise").strip().lower()
if output_mode not in {"concise", "full"}:
    output_mode = "concise"
audit_rotate_max_bytes = int(os.environ.get("SAFE_CMD_AUDIT_ROTATE_MAX_BYTES", "1048576"))
audit_rotate_max_files = int(os.environ.get("SAFE_CMD_AUDIT_ROTATE_MAX_FILES", "10"))
audit_rotate_daily = os.environ.get("SAFE_CMD_AUDIT_ROTATE_DAILY", "false") == "true"

warnings_text = read_text(os.environ["SAFE_CMD_WARNINGS_FILE"]).strip()
stdout_text = read_text(os.environ["SAFE_CMD_STDOUT_FILE"])
stderr_text = read_text(os.environ["SAFE_CMD_STDERR_FILE"])

try:
    parsed_args = json.loads(args_json)
except json.JSONDecodeError:
    parsed_args = []

if not isinstance(parsed_args, list):
    parsed_args = []

computed_context = {
    "args_json": args_json,
    "command": command_name,
    "risky": risky_command,
    "working_dir": resolved_working_dir,
}
computed_context_digest = hashlib.sha256(
    json.dumps(computed_context, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
if not auth_context_digest:
    auth_context_digest = computed_context_digest

warnings = [line for line in warnings_text.splitlines() if line]
status = "success" if exit_code == 0 else "error"
risk_level = "medium" if risky_command else "low"
if exit_code != 0:
    risk_level = "high" if risky_command else "medium"

trace_summary = {
    "line_count": 0,
    "syscall_samples": [],
}
if trace_requested and trace_supported:
    trace_text = read_text(trace_file)
    trace_lines = [line for line in trace_text.splitlines() if line]
    trace_summary["line_count"] = len(trace_lines)
    trace_summary["syscall_samples"] = trace_lines[:10]

help_excerpt = ""
explanation_source = "disabled"
provider_effective = "none"
provider_timeout_hit = False
provider_reason_code = "EXPLAIN_DISABLED"
if enable_explanation:
    explanation_source = "local-fallback"
    provider_effective = "local"
    provider_reason_code = "EXPLAIN_LOCAL"
    help_excerpt = read_text(os.environ["SAFE_CMD_STDERR_FILE"])[:1200]

    if explain_provider_requested == "none":
        explanation_source = "disabled"
        provider_effective = "none"
        provider_reason_code = "EXPLAIN_PROVIDER_DISABLED"
    elif explain_provider_requested == "explainshell":
        command_line_for_explain = " ".join([command_name, *parsed_args]).strip()
        try:
            run = subprocess.run(
                ["explainshell", command_line_for_explain],
                check=False,
                capture_output=True,
                text=True,
                timeout=max(0.1, explain_timeout_ms / 1000.0),
            )
            explain_output = (run.stdout or run.stderr or "").strip()
            if run.returncode == 0 and explain_output:
                help_excerpt = explain_output[:1200]
                explanation_source = "explainshell"
                provider_effective = "explainshell"
                provider_reason_code = "EXPLAIN_PROVIDER_OK"
            else:
                provider_reason_code = "EXPLAIN_PROVIDER_FAILED"
        except FileNotFoundError:
            provider_reason_code = "EXPLAIN_PROVIDER_UNAVAILABLE"
        except subprocess.TimeoutExpired:
            provider_timeout_hit = True
            provider_reason_code = "EXPLAIN_PROVIDER_TIMEOUT"
        except Exception:
            provider_reason_code = "EXPLAIN_PROVIDER_ERROR"

record_id = request_id or f"run-safe-command-{uuid.uuid4()}"
completed_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()

response = {
    "request": {
        "request_id": request_id,
        "command": command_name,
        "args": parsed_args,
        "working_dir": working_dir,
        "resolved_working_dir": resolved_working_dir,
        "confirm_action": confirm_action == "true",
        "enable_trace": enable_trace,
        "enable_explanation": enable_explanation,
    },
    "security": {
        "command_allowed": True,
        "risky_command": risky_command,
        "confirm_action_satisfied": auth_verified if auth_required else True,
        "working_dir_validated": True,
        "guardrails": [
            "no-shell-eval",
            "args-json-validated",
            "working-directory-validated",
            "risky-command-confirmation",
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
        "executable_path": executable_path,
        "stdout": stdout_text,
        "stderr": stderr_text,
    },
    "trace": {
        "requested": trace_requested,
        "requested_mode": trace_mode_requested,
        "effective_mode": trace_effective_mode,
        "collector": trace_collector,
        "supported": trace_supported,
        "downgrade_reason_code": trace_downgrade_reason_code,
        "warnings": warnings,
        "summary": trace_summary,
        "notes": "Linux prefers strace; darwin attempts dtruss and degrades when privileges are missing.",
    },
    "explanation": {
        "summary": "Executed command in validated working directory without shell eval.",
        "risk_level": risk_level,
        "enabled": enable_explanation,
        "provider_requested": explain_provider_requested,
        "provider_effective": provider_effective,
        "source": explanation_source,
        "timeout_hit": provider_timeout_hit,
        "reason_code": provider_reason_code,
        "help_excerpt": help_excerpt,
        "details": {
            "risky_command": risky_command,
            "confirm_action": confirm_action == "true",
            "exit_code": exit_code,
        },
    },
    "audit": {
        "record_id": record_id,
        "file": audit_file,
        "written": False,
        "rotation_applied": False,
        "rotated_files": [],
    },
}

audit_payload = {
    "record_id": record_id,
    "ts": completed_at,
    "request": response["request"],
    "security": {
        "risky_command": risky_command,
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
            stat.st_mtime,
            tz=datetime.timezone.utc,
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
        "request": full_response.get("request", {}),
        "execution": full_response.get("execution", {}),
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
