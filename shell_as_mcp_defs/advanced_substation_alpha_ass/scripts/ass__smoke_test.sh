#!/usr/bin/env bash
set -euo pipefail

ASS_FILE="${TOOL_ASS_FILE_PATH:?TOOL_ASS_FILE_PATH is required}"
OUTPUT_PATH_RAW="${TOOL_OUTPUT_PATH:?TOOL_OUTPUT_PATH is required}"
OUTPUT_DIR_FALLBACK="${TOOL_OUTPUT_DIR:-}"

if [[ "$OUTPUT_PATH_RAW" = /* ]]; then
  OUTPUT_PATH="$OUTPUT_PATH_RAW"
elif [[ -n "$OUTPUT_DIR_FALLBACK" ]]; then
  OUTPUT_PATH="${OUTPUT_DIR_FALLBACK%/}/$OUTPUT_PATH_RAW"
else
  OUTPUT_PATH="$OUTPUT_PATH_RAW"
fi

DURATION="${TOOL_DURATION_SEC:-10}"
RESOLUTION="${TOOL_RESOLUTION:-1920x1080}"
BG_COLOR="${TOOL_BACKGROUND_COLOR:-black}"

# Validate: ASS file exists and is readable
if [[ ! -r "${ASS_FILE}" ]]; then
  echo "Error: ASS file not found or not readable: ${ASS_FILE}" >&2
  exit 1
fi

# Validate: ffmpeg is available (requires libass support at compile time)
if ! command -v ffmpeg &>/dev/null; then
  echo "Error: ffmpeg is not installed. Install via: brew install ffmpeg" >&2
  exit 1
fi

# Validate: DURATION is a positive integer in range [1, 300]
if [[ ! "${DURATION}" =~ ^[0-9]+$ ]]; then
  echo "Error: duration_sec must be a positive integer, got: ${DURATION}" >&2
  exit 1
fi
if (( DURATION < 1 || DURATION > 300 )); then
  echo "Error: duration_sec must be between 1 and 300, got: ${DURATION}" >&2
  exit 1
fi

# Validate: RESOLUTION must be WxH format
if [[ ! "${RESOLUTION}" =~ ^[0-9]+x[0-9]+$ ]]; then
  echo "Error: resolution must be in WxH format (e.g. 1920x1080), got: ${RESOLUTION}" >&2
  exit 1
fi

# Resolve ASS_FILE to absolute path so the subtitles filter works regardless of cwd
ASS_FILE_ABS="$(cd "$(dirname "${ASS_FILE}")" && pwd)/$(basename "${ASS_FILE}")"

# Run ffmpeg smoke test: lavfi virtual color source + ASS subtitles overlay → MP4
# stderr is merged into stdout so it can be captured and forwarded on failure
ffmpeg_output=""
if ! ffmpeg_output=$(
  ffmpeg -y \
    -f lavfi \
    -i "color=c=${BG_COLOR}:size=${RESOLUTION}:rate=25:duration=${DURATION}" \
    -vf "subtitles=${ASS_FILE_ABS}" \
    -c:v libx264 -preset fast \
    "${OUTPUT_PATH}" 2>&1
); then
  echo "${ffmpeg_output}" >&2
  printf '{"status":"error","message":"ffmpeg failed, see stderr"}\n'
  exit 1
fi

printf '{\n  "output_path": "%s",\n  "duration_sec": %s,\n  "resolution": "%s",\n  "background_color": "%s",\n  "status": "ok"\n}\n' \
  "${OUTPUT_PATH}" "${DURATION}" "${RESOLUTION}" "${BG_COLOR}"
