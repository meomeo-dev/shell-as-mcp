#!/usr/bin/env bash
set -euo pipefail

FILE="${TOOL_ASS_FILE_PATH:?TOOL_ASS_FILE_PATH is required}"
STRICT="${TOOL_STRICT:-false}"

# ── State ────────────────────────────────────────────────────────────────────
errors=0
warnings=0
checks_passed=0
results=()

# ── Helpers ──────────────────────────────────────────────────────────────────

# Escape a value for safe embedding as a JSON string
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Append one check entry to the results array and update counters
add_result() {
  local check="$1" status="$2" message="${3:-}"
  local entry
  if [[ -n "$message" ]]; then
    local msg_esc
    msg_esc="$(json_escape "$message")"
    entry="{\"check\":\"${check}\",\"status\":\"${status}\",\"message\":\"${msg_esc}\"}"
  else
    entry="{\"check\":\"${check}\",\"status\":\"${status}\"}"
  fi
  results+=("$entry")
  case "$status" in
    PASS) checks_passed=$((checks_passed + 1)) ;;
    FAIL) errors=$((errors + 1)) ;;
    WARN) warnings=$((warnings + 1)) ;;
  esac
}

# Emit collected results as a single-line JSON document, then exit
emit_json() {
  local exit_code="${1:-0}"
  local file_esc json_array="" first=true
  file_esc="$(json_escape "$FILE")"
  for r in "${results[@]}"; do
    if [[ "$first" == "true" ]]; then
      json_array="$r"
      first=false
    else
      json_array="${json_array},${r}"
    fi
  done
  printf '{"file":"%s","errors":%d,"warnings":%d,"checks_passed":%d,"results":[%s]}\n' \
    "$file_esc" "$errors" "$warnings" "$checks_passed" "$json_array"
  exit "$exit_code"
}

# ── Check 1: File exists and is readable (ERROR, early-exit on fail) ─────────
if [[ ! -r "$FILE" ]]; then
  file_esc="$(json_escape "$FILE")"
  printf '{"file":"%s","errors":1,"warnings":0,"checks_passed":0,"results":[{"check":"file_exists","status":"FAIL","message":"File does not exist or is not readable"}]}\n' \
    "$file_esc"
  exit 1
fi
add_result "file_exists" "PASS"

# ── Check 2: UTF-8 encoding (WARNING) ────────────────────────────────────────
if command -v iconv > /dev/null 2>&1; then
  if iconv -f utf-8 -t utf-8 "$FILE" > /dev/null 2>&1; then
    add_result "utf8_encoding" "PASS"
  else
    add_result "utf8_encoding" "WARN" "File may contain non-UTF-8 bytes"
  fi
else
  add_result "utf8_encoding" "WARN" "iconv not available, check skipped"
fi

# ── Check 3: [Script Info] section header (ERROR) ────────────────────────────
if grep -qE '^\[Script Info\]' "$FILE"; then
  add_result "section_script_info" "PASS"
else
  add_result "section_script_info" "FAIL" "[Script Info] section header not found"
fi

# ── Check 4: [V4+ Styles] section header (ERROR) ─────────────────────────────
if grep -qE '^\[V4\+ Styles\]' "$FILE"; then
  add_result "section_v4_styles" "PASS"
else
  add_result "section_v4_styles" "FAIL" "[V4+ Styles] section header not found"
fi

# ── Check 5: [Events] section header (ERROR) ─────────────────────────────────
if grep -qE '^\[Events\]' "$FILE"; then
  add_result "section_events" "PASS"
else
  add_result "section_events" "FAIL" "[Events] section header not found"
fi

# ── Check 6: ScriptType: v4.00+ in [Script Info] (ERROR) ─────────────────────
if grep -qF 'ScriptType: v4.00+' "$FILE"; then
  add_result "script_type" "PASS"
else
  add_result "script_type" "FAIL" "ScriptType: v4.00+ not found in [Script Info]"
fi

# ── Check 7: PlayResX in [Script Info] (WARNING) ─────────────────────────────
if grep -qE '^PlayResX:' "$FILE"; then
  add_result "play_res_x" "PASS"
else
  add_result "play_res_x" "WARN" "PlayResX not found in [Script Info]"
fi

# ── Check 8: PlayResY in [Script Info] (WARNING) ─────────────────────────────
if grep -qE '^PlayResY:' "$FILE"; then
  add_result "play_res_y" "PASS"
else
  add_result "play_res_y" "WARN" "PlayResY not found in [Script Info]"
fi

# ── Check 9: Format: line inside [V4+ Styles] (ERROR) ────────────────────────
if awk '
  BEGIN { in_s=0; found=0 }
  /^\[V4[+] Styles\]/ { in_s=1; next }
  /^\[/ { in_s=0 }
  in_s && /^Format:/ { found=1 }
  END { exit (found ? 0 : 1) }
' "$FILE"; then
  add_result "styles_format_line" "PASS"
else
  add_result "styles_format_line" "FAIL" "Format: line not found in [V4+ Styles]"
fi

# ── Check 10: At least one Style: line inside [V4+ Styles] (ERROR) ───────────
if awk '
  BEGIN { in_s=0; found=0 }
  /^\[V4[+] Styles\]/ { in_s=1; next }
  /^\[/ { in_s=0 }
  in_s && /^Style:/ { found=1 }
  END { exit (found ? 0 : 1) }
' "$FILE"; then
  add_result "styles_style_lines" "PASS"
else
  add_result "styles_style_lines" "FAIL" "No Style: lines found in [V4+ Styles]"
fi

# ── Check 11: Format: line inside [Events] (ERROR) ───────────────────────────
if awk '
  BEGIN { in_e=0; found=0 }
  /^\[Events\]/ { in_e=1; next }
  /^\[/ { in_e=0 }
  in_e && /^Format:/ { found=1 }
  END { exit (found ? 0 : 1) }
' "$FILE"; then
  add_result "events_format_line" "PASS"
else
  add_result "events_format_line" "FAIL" "Format: line not found in [Events]"
fi

# ── Check 12: At least one Dialogue: line inside [Events] (ERROR) ────────────
if awk '
  BEGIN { in_e=0; found=0 }
  /^\[Events\]/ { in_e=1; next }
  /^\[/ { in_e=0 }
  in_e && /^Dialogue:/ { found=1 }
  END { exit (found ? 0 : 1) }
' "$FILE"; then
  add_result "events_dialogue_lines" "PASS"
else
  add_result "events_dialogue_lines" "FAIL" "No Dialogue: lines found in [Events]"
fi

# ── Check 13: Dialogue time fields match H:MM:SS.cs (ERROR) ──────────────────
# Dialogue line: "Dialogue: Layer,Start,End,..." → $1=prefix+Layer, $2=Start, $3=End
bad_times=$(awk -F',' '
  /^Dialogue:/ {
    start=$2; end=$3
    if (start !~ /^[0-9]:[0-5][0-9]:[0-5][0-9]\.[0-9][0-9]$/) {
      print "line " NR ": bad start [" start "]"
    }
    if (end !~ /^[0-9]:[0-5][0-9]:[0-5][0-9]\.[0-9][0-9]$/) {
      print "line " NR ": bad end [" end "]"
    }
  }
' "$FILE")
if [[ -z "$bad_times" ]]; then
  add_result "dialogue_time_format" "PASS"
else
  count=$(printf '%s\n' "$bad_times" | wc -l | tr -d ' ')
  add_result "dialogue_time_format" "FAIL" "${count} invalid time field(s) found"
fi

# ── Check 14: Style color fields match &H[0-9A-Fa-f]{8} (WARNING) ────────────
bad_colors=$(awk -F',' '
  /^Style:/ {
    for (i=1; i<=NF; i++) {
      f=$i; gsub(/^[ \t]+|[ \t]+$/, "", f)
      if (f ~ /^&H/ && f !~ /^&H[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) {
        print "line " NR ": invalid color [" f "]"
      }
    }
  }
' "$FILE")
if [[ -z "$bad_colors" ]]; then
  add_result "style_color_format" "PASS"
else
  count=$(printf '%s\n' "$bad_colors" | wc -l | tr -d ' ')
  add_result "style_color_format" "WARN" "${count} invalid color field(s) found in Style lines"
fi

# ── Checks 15 & 16: strict mode only ─────────────────────────────────────────
if [[ "$STRICT" == "true" ]]; then

  # Check 15: Each Dialogue line has >= 10 comma-separated fields (ERROR)
  # Text field may contain commas, so NF >= 10 is the requirement
  bad_dialogue=$(awk -F',' '
    /^Dialogue:/ && NF < 10 { print "line " NR ": " NF " fields (need >=10)" }
  ' "$FILE")
  if [[ -z "$bad_dialogue" ]]; then
    add_result "dialogue_field_count" "PASS"
  else
    count=$(printf '%s\n' "$bad_dialogue" | wc -l | tr -d ' ')
    add_result "dialogue_field_count" "FAIL" "${count} Dialogue line(s) have fewer than 10 fields"
  fi

  # Check 16: Each Style line has exactly 23 comma-separated fields (ERROR)
  bad_style=$(awk -F',' '
    /^Style:/ && NF != 23 { print "line " NR ": " NF " fields (need 23)" }
  ' "$FILE")
  if [[ -z "$bad_style" ]]; then
    add_result "style_field_count" "PASS"
  else
    count=$(printf '%s\n' "$bad_style" | wc -l | tr -d ' ')
    add_result "style_field_count" "FAIL" "${count} Style line(s) have incorrect field count (expected 23)"
  fi

fi

# ── Emit final JSON ───────────────────────────────────────────────────────────
if [[ "$errors" -gt 0 ]]; then
  emit_json 1
else
  emit_json 0
fi
