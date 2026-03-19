#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCD_BASE="$REPO_ROOT/shell_as_mcp_defs"

total=0
passed=0
skipped=0
failed=0
failed_bundles=()

# Run a single smoke test script and record result.
# exit 0 with "SKIP:" prefix on stdout/stderr => SKIP
# exit 0 without "SKIP:" prefix                => PASS
# exit non-0                                   => FAIL
run_smoke() {
  local name="$1"
  local script="$2"
  total=$((total + 1))

  local output exit_code
  set +e
  output="$(bash "$script" 2>&1)"
  exit_code=$?
  set -e

  if [[ $exit_code -ne 0 ]]; then
    echo "[FAIL]  $name"
    echo "        output: $output"
    failed=$((failed + 1))
    failed_bundles+=("$name")
  elif echo "$output" | grep -q "^SKIP:"; then
    echo "[SKIP]  $name  ($output)"
    skipped=$((skipped + 1))
  else
    echo "[PASS]  $name  $output"
    passed=$((passed + 1))
  fi
}

# ── ass bundle: requires ffmpeg + a real .ass file via env vars ──────────────
run_smoke_ass() {
  local name="ass"
  local script="$MCD_BASE/advanced_substation_alpha_ass/scripts/ass__smoke_test.sh"
  [[ -f "$script" ]] || { echo "[SKIP]  $name  (smoke script not found)"; skipped=$((skipped+1)); total=$((total+1)); return; }

  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "[SKIP]  $name  (ffmpeg not found)"
    skipped=$((skipped + 1))
    total=$((total + 1))
    return
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP]  $name  (python3 not found, cannot create temp ASS file)"
    skipped=$((skipped + 1))
    total=$((total + 1))
    return
  fi

  # Create minimal valid ASS file in /tmp
  local tmpdir
  tmpdir="$(mktemp -d /tmp/smoke_ass_XXXXXX)"
  local ass_file="$tmpdir/smoke.ass"
  local out_dir="$tmpdir/out"
  mkdir -p "$out_dir"

  python3 -c "
import sys
content = (
    '[Script Info]\n'
    'ScriptType: v4.00+\n'
    'PlayResX: 320\n'
    'PlayResY: 240\n'
    '[V4+ Styles]\n'
    'Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding\n'
    'Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1\n'
    '[Events]\n'
    'Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text\n'
    'Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,Smoke Test\n'
)
with open(sys.argv[1], 'w') as f:
    f.write(content)
" "$ass_file"

  total=$((total + 1))
  local output exit_code
  set +e
  output="$(
    TOOL_ASS_FILE_PATH="$ass_file" \
    TOOL_OUTPUT_PATH="$out_dir/smoke_out.mp4" \
    TOOL_DURATION_SEC="1" \
    TOOL_RESOLUTION="320x240" \
    bash "$script" 2>&1
  )"
  exit_code=$?
  set -e

  rm -rf "$tmpdir"

  if [[ $exit_code -ne 0 ]]; then
    echo "[FAIL]  $name"
    echo "        output: $output"
    failed=$((failed + 1))
    failed_bundles+=("$name")
  elif echo "$output" | grep -q "^SKIP:"; then
    echo "[SKIP]  $name  ($output)"
    skipped=$((skipped + 1))
  else
    echo "[PASS]  $name  $output"
    passed=$((passed + 1))
  fi
}

# ── Run all smoke tests ──────────────────────────────────────────────────────
run_smoke_ass

for bundle in brew ffmpeg host_info run_safe_command runprompt__generate_artifact shell ytdlp; do
  # runprompt bundle smoke script is named runprompt__smoke_test.sh
  if [[ "$bundle" == "runprompt__generate_artifact" ]]; then
    smoke="$MCD_BASE/$bundle/scripts/runprompt__smoke_test.sh"
  else
    smoke="$MCD_BASE/$bundle/scripts/${bundle}__smoke_test.sh"
  fi
  [[ -f "$smoke" ]] || continue
  run_smoke "$bundle" "$smoke"
done

# ── Run per-target smoke tests for current platform ──────────────────────
# Auto-discovers *__smoke_test__{kernel}_{arch}.sh scripts (e.g. darwin_arm64)
# and runs them. On non-matching platforms they self-skip via uname guard.
current_target="$(uname -s | tr '[:upper:]' '[:lower:]')_$(uname -m)"
while IFS= read -r -d '' target_script; do
  name="$(basename "$target_script" .sh)"
  run_smoke "$name" "$target_script"
done < <(find "$MCD_BASE" -path "*/scripts/*__smoke_test__${current_target}.sh" -print0 2>/dev/null | sort -z)

echo ""
echo "=== Smoke Test Summary: $total run, $passed passed, $skipped skipped, $failed failed ==="

if [[ $failed -gt 0 ]]; then
  echo "Failed bundles: ${failed_bundles[*]}" >&2
  exit 1
fi
