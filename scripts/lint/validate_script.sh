#!/usr/bin/env bash
set -euo pipefail

# Validate shell script files.
# Usage: validate_script.sh <file1> [file2 ...]
# Exits 0 if all pass, 1 if any fail.

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <script-file> [...]" >&2
  exit 2
fi

fail_count=0

check_file() {
  local filepath="$1"
  local errors=()

  # Rule 1: first line must be '#!/usr/bin/env bash'
  local first_line
  first_line=$(head -1 "$filepath")
  if [[ "$first_line" != "#!/usr/bin/env bash" ]]; then
    errors+=("first line must be '#!/usr/bin/env bash', got: $first_line")
  fi

  # Rule 2: second non-empty line (after shebang) must contain 'set -euo pipefail'
  local second_nonempty
  second_nonempty=$(awk 'NR>1 && /[^[:space:]]/{print; exit}' "$filepath")
  if [[ "$second_nonempty" != *"set -euo pipefail"* ]] && \
     [[ "$second_nonempty" != *"set -eu -o pipefail"* ]]; then
    errors+=(
      "second non-empty line must contain 'set -euo pipefail', got: $second_nonempty"
    )
  fi

  # Rule 3: run shellcheck if available
  if command -v shellcheck > /dev/null 2>&1; then
    local sc_dir sc_name
    sc_dir="$(dirname "$filepath")"
    sc_name="$(basename "$filepath")"
    if ! (cd "$sc_dir" && shellcheck -x "$sc_name" > /dev/null 2>&1); then
      local sc_output
      sc_output=$(cd "$sc_dir" && shellcheck -x "$sc_name" 2>&1 || true)
      errors+=("shellcheck failed:")
      while IFS= read -r line; do
        errors+=("  $line")
      done <<< "$sc_output"
    fi
  else
    echo "       [WARN] shellcheck not found in PATH, skipping shellcheck for $filepath"
  fi

  if [[ ${#errors[@]} -eq 0 ]]; then
    echo "[PASS] $filepath"
    return 0
  else
    echo "[FAIL] $filepath"
    for e in "${errors[@]}"; do
      echo "       -> $e"
    done
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
