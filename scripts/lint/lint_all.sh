#!/usr/bin/env bash
set -euo pipefail

# Unified lint entry point.
# Discovers all command MCD files and validates them with their respective validators.
# Usage: lint_all.sh
# Exits 0 if all checks pass, 1 if any fail.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MCD_BASE="$REPO_ROOT/shell_as_mcp_defs"

VALIDATE_YAML="$SCRIPT_DIR/validate_shell_as_mcp_yaml.sh"
VALIDATE_PROMPT="$SCRIPT_DIR/validate_runprompt_prompt.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate_script.sh"

total=0
passed=0
failed=0

run_check() {
  local validator="$1"
  shift
  local files=("$@")
  if [[ ${#files[@]} -eq 0 ]]; then
    return 0
  fi
  for f in "${files[@]}"; do
    total=$((total + 1))
    if bash "$validator" "$f"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
  done
}

# ── shell-as-mcp yaml checks ─────────────────────────────────────────────────
echo "=== shell-as-mcp yaml checks ==="
yaml_files=()
while IFS= read -r -d '' f; do
  yaml_files+=("$f")
done < <(find "$MCD_BASE" -path "*/spec_yaml/*.yaml" -print0 2>/dev/null | sort -z)
run_check "$VALIDATE_YAML" "${yaml_files[@]+"${yaml_files[@]}"}"
echo ""

# ── script checks ─────────────────────────────────────────────────────────
echo "=== script checks ==="
sh_files=()
while IFS= read -r -d '' f; do
  sh_files+=("$f")
done < <(find "$MCD_BASE" -path "*/scripts/*.sh" -print0 2>/dev/null | sort -z)
run_check "$VALIDATE_SCRIPT" "${sh_files[@]+"${sh_files[@]}"}"
echo ""

# ── runprompt-prompt checks ───────────────────────────────────────────────
echo "=== runprompt-prompt checks ==="
prompt_files=()
while IFS= read -r -d '' f; do
  # skip _*.prompt partials
  basename_f="$(basename "$f")"
  if [[ "$basename_f" == _* ]]; then
    continue
  fi
  prompt_files+=("$f")
done < <(find "$MCD_BASE" -path "*/prompts/*.prompt" -print0 2>/dev/null | sort -z)
run_check "$VALIDATE_PROMPT" "${prompt_files[@]+"${prompt_files[@]}"}"
echo ""

# ── tested targets must have smoke_test.sh ────────────────────────────────
echo "=== tested→smoke_test enforcement ==="
VALIDATE_TESTED_SMOKE="$SCRIPT_DIR/validate_tested_has_smoke_test.sh"
run_check "$VALIDATE_TESTED_SMOKE" "${yaml_files[@]+"${yaml_files[@]}"}"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────
echo "=== Summary: $total files checked, $passed passed, $failed failed ==="

if [[ $failed -gt 0 ]]; then
  exit 1
fi
