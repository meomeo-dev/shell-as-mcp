#!/usr/bin/env bash
set -euo pipefail

# Validate shell-as-mcp YAML spec files.
# Usage: validate_shell_as_mcp_yaml.sh <file1> [file2 ...]
# Exits 0 if all pass, 1 if any fail.

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <yaml-file> [...]" >&2
  exit 2
fi

fail_count=0

check_file() {
  local filepath="$1"
  local result
  if result=$(python3 - "$filepath" <<'PYEOF'
import sys
import yaml

filepath = sys.argv[1]
errors = []

with open(filepath, encoding="utf-8") as f:
    doc = yaml.safe_load(f)

if not isinstance(doc, dict):
    errors.append("document is not a YAML mapping")
    print("\n".join(errors))
    sys.exit(1)

if doc.get("apiVersion") != "v1":
    errors.append("apiVersion must be 'v1'")

tool = doc.get("tool") or {}
if not tool.get("name"):
    errors.append("tool.name is required and must be non-empty")

desc = str(tool.get("description") or "")
if "/**" not in desc or "*/" not in desc:
    errors.append("tool.description must be a TSDoc block comment (/** ... */)")

if "docstring" in (tool or {}):
    errors.append("tool.docstring is not supported; use tool.description instead")

tool_input = tool.get("input")
if not isinstance(tool_input, dict):
  errors.append("tool.input is required and must be a mapping")
else:
  if "properties" not in tool_input:
    errors.append("tool.input.properties is required")
  elif not isinstance(tool_input.get("properties"), dict):
    errors.append("tool.input.properties must be a mapping")

out_props = ((tool.get("output") or {}).get("properties")) or {}
required_out = {"status", "exit_code", "stdout", "stderr", "command", "execution_time_ms"}
missing_out = required_out - set(out_props.keys())
if missing_out:
    errors.append(
        "tool.output.properties missing: " + ", ".join(sorted(missing_out))
    )

execution = doc.get("execution") or {}
has_cmd = "command" in execution
has_script = "script" in execution

env = execution.get("env") if isinstance(execution, dict) else None
if isinstance(env, dict):
    static = env.get("static")
    if static is not None:
        if not isinstance(static, dict):
            errors.append("execution.env.static must be a mapping")
        else:
            for k, v in static.items():
                if not isinstance(v, str):
                    errors.append(f"execution.env.static.{k} must be a string")
    from_params = env.get("fromParams")
    if from_params is not None:
        if not isinstance(from_params, dict):
            errors.append("execution.env.fromParams must be a mapping")
        else:
            for k, v in from_params.items():
                if not isinstance(v, str):
                    errors.append(f"execution.env.fromParams.{k} must be a string")
    from_runtime = env.get("fromRuntime")
    if from_runtime is not None:
        if not isinstance(from_runtime, dict):
            errors.append("execution.env.fromRuntime must be a mapping")
        else:
            for k, v in from_runtime.items():
                valid = (isinstance(v, str) and len(v) > 0) or \
                        (isinstance(v, list) and len(v) > 0 and all(isinstance(e, str) and len(e) > 0 for e in v))
                if not valid:
                    errors.append(
                        f"execution.env.fromRuntime.{k} must be a non-empty string or array of non-empty strings"
                    )
elif env is not None:
    errors.append("execution.env must be a mapping")

if has_cmd and has_script:
    errors.append(
        "execution must define exactly one of 'command' or 'script', not both"
    )
elif not has_cmd and not has_script:
    errors.append("execution must define exactly one of 'command' or 'script'")

if has_cmd:
    cmd_block = execution.get("command") if isinstance(execution, dict) else None
    executable = cmd_block.get("executable") if isinstance(cmd_block, dict) else None
    if not isinstance(executable, str) or len(executable) == 0:
        errors.append("execution.command.executable must be a non-empty string")

if has_script:
    script_block = execution.get("script") if isinstance(execution, dict) else None
    script_path = script_block.get("path") if isinstance(script_block, dict) else None
    if not isinstance(script_path, str) or len(script_path) == 0:
        errors.append("execution.script.path must be a non-empty string")

compatibility = execution.get("compatibility")
if compatibility is not None:
  if not isinstance(compatibility, dict):
    errors.append("execution.compatibility must be a mapping")
  else:
    targets = compatibility.get("targets")
    if not isinstance(targets, list) or len(targets) == 0:
      errors.append("execution.compatibility.targets must be a non-empty array")
    else:
      for index, target in enumerate(targets):
        if not isinstance(target, dict):
          errors.append(
            f"execution.compatibility.targets[{index}] must be a mapping"
          )
          continue

        for key in ("os", "kernel", "arch"):
          value = target.get(key)
          if not isinstance(value, str) or not value:
            errors.append(
              f"execution.compatibility.targets[{index}].{key} must be a non-empty string"
            )

        support = target.get("support")
        if support is not None and support not in {"tested", "declared"}:
          errors.append(
            f"execution.compatibility.targets[{index}].support must be 'tested' or 'declared'"
          )

        notes = target.get("notes")
        if notes is not None and not isinstance(notes, str):
          errors.append(
            f"execution.compatibility.targets[{index}].notes must be a string"
          )

task_mode = execution.get("taskMode") if isinstance(execution, dict) else None
if task_mode is not None and task_mode not in ("sync", "async"):
    errors.append(
        "execution.taskMode must be 'sync' or 'async' (got: " + repr(task_mode) + ")"
    )

if errors:
    for e in errors:
        print(e)
    sys.exit(1)
sys.exit(0)
PYEOF
  ); then
    echo "[PASS] $filepath"
    return 0
  else
    echo "[FAIL] $filepath"
    while IFS= read -r line; do
      echo "       -> $line"
    done <<< "$result"
    return 1
  fi
}

for f in "$@"; do
  if ! check_file "$f"; then
    fail_count=$((fail_count + 1))
  fi
done

if [[ $fail_count -gt 0 ]]; then
  exit 1
fi
