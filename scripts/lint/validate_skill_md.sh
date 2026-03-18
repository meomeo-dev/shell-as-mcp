#!/usr/bin/env bash
set -euo pipefail

# Validate SKILL.md files against claude-skill.spec.md requirements.
# Covers all 9 items from the Validation checklist.
# Usage: validate_skill_md.sh <file1> [file2 ...]
# Exits 0 if all pass, 1 if any fail.

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <skill-md-file> [...]" >&2
  exit 2
fi

fail_count=0

# ── helpers ─────────────────────────────────────────────────────────────────

_frontmatter() {
  # Print lines between opening and closing '---'
  awk 'BEGIN{count=0} /^---$/{count++; if(count==2)exit; next} count==1{print}' "$1"
}

_body() {
  # Print lines after the closing '---'
  awk 'BEGIN{count=0} /^---$/{count++; next} count>=2{print}' "$1"
}

_section() {
  # Extract content of a named ## section until the next ## heading
  local body="$1"
  local sec="$2"
  echo "$body" | awk -v sec="$sec" \
    'BEGIN{found=0}
     /^## /{if(found){exit}; if($0 ~ ("^## " sec)){found=1}; next}
     found{print}'
}

# ── per-file checker ────────────────────────────────────────────────────────

check_file() {
  local filepath="$1"
  local errors=()

  # ── C1: valid YAML frontmatter with name + description ───────────────────
  local sep_count second_sep
  sep_count=$(grep -c '^---$' "$filepath" || true)
  second_sep=$(awk '/^---$/{count++; if(count==2){print NR; exit}}' "$filepath" || true)

  if [[ "$sep_count" -lt 2 ]] || [[ -z "$second_sep" ]]; then
    errors+=("C1: missing YAML frontmatter ('---' delimiters not found)")
  fi

  local fm
  fm=$(_frontmatter "$filepath")

  if ! echo "$fm" | grep -qE '^name:[[:space:]]*\S'; then
    errors+=("C1: frontmatter missing non-empty 'name' field")
  fi
  if ! echo "$fm" | grep -qE '^description:[[:space:]]*\S'; then
    errors+=("C1: frontmatter missing non-empty 'description' field")
  fi

  # ── C2: name is kebab-case [a-z0-9-]+ ────────────────────────────────────
  local name_val
  name_val=$(echo "$fm" | grep -E '^name:' | head -1 \
    | sed 's/^name:[[:space:]]*//' | tr -d "\"'" | tr -d '\r')
  if [[ -n "$name_val" ]] && ! echo "$name_val" | grep -qE '^[a-z0-9-]+$'; then
    errors+=("C2: 'name' is not kebab-case: '$name_val' (must match [a-z0-9-]+)")
  fi

  # ── C3: invocation semantics in given-when-to OR description(Use when) ───
  local desc_line
  desc_line=$(echo "$fm" | grep -E '^description:' | head -1)

  local has_desc_usewhen="no"
  local has_gwt_struct="no"

  if [[ -n "$desc_line" ]] && echo "$desc_line" | grep -iqE 'use when'; then
    has_desc_usewhen="yes"
  fi

  # Accept semantic frontmatter block:
  # given-when-to:
  #   - given: ...
  #     when_to: ...
  local gwt_check
  gwt_check=$(echo "$fm" | awk '
    BEGIN { in_gwt=0; has_item_given=0; has_item_when=0 }
    /^given-when-to:[[:space:]]*$/ { in_gwt=1; next }
    in_gwt && /^[^[:space:]-][^:]*:/ { in_gwt=0 }
    in_gwt && /^[[:space:]]*-[[:space:]]*given:[[:space:]]*[^[:space:]].*/ {
      has_item_given=1
      next
    }
    in_gwt && /^[[:space:]]*when_to:[[:space:]]*[^[:space:]].*/ {
      has_item_when=1
      next
    }
    END {
      if (has_item_given && has_item_when) print "yes"; else print "no"
    }
  ')
  if [[ "$gwt_check" == "yes" ]]; then
    has_gwt_struct="yes"
  fi

  if [[ "$has_desc_usewhen" != "yes" ]] && [[ "$has_gwt_struct" != "yes" ]]; then
    errors+=(
      "C3: invocation semantics missing; provide either given-when-to list or "
      "'Use when ...' in description"
    )
  fi

  # ── C4: required body sections present ───────────────────────────────────
  local body
  body=$(_body "$filepath")

  for section in "Scope" "Core Rules" "Workflow"; do
    if ! echo "$body" | grep -qE "^## $section"; then
      errors+=("C4: missing required body section: '## $section'")
    fi
  done

  # ── C5: Core Rules has at least 3 rules ──────────────────────────────────
  local core_content rule_count
  core_content=$(_section "$body" "Core Rules")
  # Count: "### N. Title" subheadings OR "N. item" numbered list items
  rule_count=$(echo "$core_content" \
    | grep -cE '^(### [0-9]+\.|[[:space:]]*[0-9]+\. )' || true)
  if [[ "$rule_count" -lt 3 ]]; then
    errors+=("C5: 'Core Rules' has $rule_count rule(s); need at least 3")
  fi

  # ── C6: Workflow section has content ─────────────────────────────────────
  local workflow_content
  workflow_content=$(_section "$body" "Workflow" \
    | grep -vE '^[[:space:]]*$' || true)
  if [[ -z "$workflow_content" ]]; then
    errors+=("C6: 'Workflow' section is empty")
  fi

  # ── C7 + C8: Resources paths are repo-relative and not gitignore-ignored ──
  local resources_content

  # C7: no absolute paths inside Resources section
  resources_content=$(_section "$body" "Resources")
  local abs_in_resources
  abs_in_resources=$(echo "$resources_content" | grep -oE '`/[^`]+`' || true)
  if [[ -n "$abs_in_resources" ]]; then
    while IFS= read -r ref; do
      errors+=("C7: absolute path in Resources section: $ref")
    done <<< "$abs_in_resources"
  fi

  # C8: no forbidden (gitignore-ignored) path references in Resources section
  local forbidden_prefixes=(
    'tasks/'
    'tmp/'
    'dist/'
    'node_modules/'
    '__pycache__/'
    '\.kms/'
    '\.todo_tasks/'
    '\.vscode/'
    '\.idea/'
  )
  for prefix in "${forbidden_prefixes[@]}"; do
    local matches
    matches=$(echo "$resources_content" \
      | grep -oE '`[^`]+`' | grep -E "(^|\`[[:space:]]*)$prefix" || true)
    if [[ -n "$matches" ]]; then
      while IFS= read -r m; do
        errors+=("C8: reference to .gitignore-ignored path in Resources: $m")
      done <<< "$matches"
    fi
  done

  # C8: standalone .env references anywhere in body
  if echo "$body" | grep -oE '`[^`]+`' | grep -qE '^`\.env($|[^a-zA-Z])'; then
    errors+=("C8: reference to '.env' (gitignore-ignored) in body")
  fi

  # ── C9: no machine-local absolute paths anywhere in body ─────────────────
  local abs_paths
  abs_paths=$(echo "$body" \
    | grep -oE '`(/Users|/home|/root|/var|/opt|/etc)/[^`]*`' || true)
  if [[ -n "$abs_paths" ]]; then
    while IFS= read -r ref; do
      errors+=("C9: machine-local absolute path reference: $ref")
    done <<< "$abs_paths"
  fi

  # ── result ────────────────────────────────────────────────────────────────
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
