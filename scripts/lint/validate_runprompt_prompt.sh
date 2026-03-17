#!/usr/bin/env bash
set -euo pipefail

# Validate runprompt .prompt files.
# Usage: validate_runprompt_prompt.sh <file1> [file2 ...]
# Exits 0 if all pass, 1 if any fail.

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <prompt-file> [...]" >&2
  exit 2
fi

fail_count=0

check_file() {
  local filepath="$1"
  local errors=()

  # Rule 1: must not contain Markdown fences (```)
  if grep -qF '```' "$filepath"; then
    errors+=("must not contain Markdown fences (backtick triple)")
  fi

  # Rule 2: first non-empty line must be '---'
  local first_line
  first_line=$(grep -m1 '[^[:space:]]' "$filepath" || true)
  if [[ "$first_line" != "---" ]]; then
    errors+=("first non-empty line must be '---' (YAML frontmatter start)")
  fi

  # Rule 3: second '---' line must exist (line number > 1)
  local second_sep_lineno
  second_sep_lineno=$(awk '/^---$/{count++; if(count==2){print NR; exit}}' "$filepath" || true)
  if [[ -z "$second_sep_lineno" ]]; then
    errors+=("frontmatter closing '---' line not found")
  fi

  # Rule 4: frontmatter must contain non-empty 'model:' key
  if [[ -n "$second_sep_lineno" ]]; then
    local has_model
    has_model=$(awk "
      /^---\$/{count++; if(count==2) exit}
      count==1 && /^model:[[:space:]]*[^[:space:]]/{found=1}
      END{print (found ? \"yes\" : \"no\")}
    " "$filepath")
    if [[ "$has_model" != "yes" ]]; then
      errors+=("frontmatter must contain a non-empty 'model:' key")
    fi
  fi

  # Rule 5: body after frontmatter must have at least one non-empty line
  if [[ -n "$second_sep_lineno" ]]; then
    local has_body
    has_body=$(awk "
      /^---\$/{count++; next}
      count>=2 && /[^[:space:]]/{found=1; exit}
      END{print (found ? \"yes\" : \"no\")}
    " "$filepath")
    if [[ "$has_body" != "yes" ]]; then
      errors+=("template body after frontmatter is empty")
    fi
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
