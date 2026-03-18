#!/usr/bin/env bash
set -euo pipefail

# Validate: each 'support: tested' target in a bundle spec YAML must have
# a corresponding {prefix}__smoke_test__{kernel}_{arch}.sh in the bundle's scripts dir.
# Usage: validate_tested_has_smoke_test.sh <yaml-file>
# Exits 0 if all tested targets have a per-target smoke test script.
# Exits 1 if any tested target is missing its smoke test script.
# Exits 2 if no argument given.

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <yaml-file>" >&2
  exit 2
fi

filepath="$1"

# Derive bundle directory from YAML path:
#   .../shell_as_mcp_defs/{bundle}/spec_yaml/{tool}.yaml
#            ^bundle_dir = parent of spec_yaml dir^
bundle_dir="$(cd "$(dirname "$filepath")/.." && pwd)"
scripts_dir="$bundle_dir/scripts"

# Detect smoke test script prefix by finding any *__smoke_test.sh (generic, no target suffix).
# This handles bundles where the prefix differs from the dir name:
#   advanced_substation_alpha_ass/ → ass__smoke_test.sh → prefix=ass
#   runprompt__generate_artifact/ → runprompt__smoke_test.sh → prefix=runprompt
smoke_prefix=""
for candidate in "$scripts_dir"/*__smoke_test.sh; do
  if [[ -f "$candidate" ]]; then
    basename_cand="$(basename "$candidate")"
    smoke_prefix="${basename_cand%%__smoke_test.sh}"
    break
  fi
done

# Parse YAML to extract kernel_arch pairs for all 'support: tested' targets.
# Uses POSIX awk for portable parsing without external YAML library dependencies.
# $NF extracts the last whitespace-delimited token from each matched line:
#   "        kernel: darwin"  → $NF = "darwin"
#   "        arch: arm64"     → $NF = "arm64"
# YAML values in compatibility.targets are always bare single tokens (no inline comments).
tested_targets="$(awk '
  /^[[:space:]]+-[[:space:]]+os:/ { kernel=""; arch="" }
  /^[[:space:]]+kernel:/           { kernel=$NF }
  /^[[:space:]]+arch:/             { arch=$NF }
  /^[[:space:]]+support:[[:space:]]+tested/ {
    if (kernel != "" && arch != "") print kernel "_" arch
  }
' "$filepath")"

if [[ -z "$tested_targets" ]]; then
  echo "OK: $filepath → no 'tested' targets (declared only)"
  exit 0
fi

if [[ -z "$smoke_prefix" ]]; then
  echo "ERROR: $filepath has 'tested' targets but no *__smoke_test.sh anchor found in: $scripts_dir" >&2
  exit 1
fi

fail=0
while IFS= read -r target; do
  [[ -z "$target" ]] && continue
  expected="${scripts_dir}/${smoke_prefix}__smoke_test__${target}.sh"
  if [[ -f "$expected" ]]; then
    echo "OK: $filepath → [${target}] $(basename "$expected")"
  else
    echo "ERROR: $filepath → [${target}] missing per-target smoke test: $(basename "$expected")" >&2
    fail=1
  fi
done <<< "$tested_targets"

exit "$fail"
