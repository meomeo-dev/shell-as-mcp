#!/usr/bin/env bash
set -euo pipefail

OUTPUT_PATH_RAW="${TOOL_OUTPUT_PATH:?TOOL_OUTPUT_PATH is required}"
OUTPUT_DIR_FALLBACK="${TOOL_OUTPUT_DIR:-}"

if [[ "$OUTPUT_PATH_RAW" = /* ]]; then
  OUTPUT_PATH="$OUTPUT_PATH_RAW"
elif [[ -n "$OUTPUT_DIR_FALLBACK" ]]; then
  OUTPUT_PATH="${OUTPUT_DIR_FALLBACK%/}/$OUTPUT_PATH_RAW"
else
  OUTPUT_PATH="$OUTPUT_PATH_RAW"
fi

TITLE="${TOOL_TITLE:-Untitled}"
PLAY_RES_X="${TOOL_PLAY_RES_X:-1920}"
PLAY_RES_Y="${TOOL_PLAY_RES_Y:-1080}"
OVERWRITE="${TOOL_OVERWRITE:-false}"

# Validate PLAY_RES_X: must be a positive integer
if ! [[ "$PLAY_RES_X" =~ ^[1-9][0-9]*$ ]]; then
  echo "Warning: PLAY_RES_X='$PLAY_RES_X' is not a positive integer; using default 1920." >&2
  PLAY_RES_X="1920"
fi

# Validate PLAY_RES_Y: must be a positive integer
if ! [[ "$PLAY_RES_Y" =~ ^[1-9][0-9]*$ ]]; then
  echo "Warning: PLAY_RES_Y='$PLAY_RES_Y' is not a positive integer; using default 1080." >&2
  PLAY_RES_Y="1080"
fi

# Guard against overwriting existing file
if [[ "$OVERWRITE" != "true" && -e "$OUTPUT_PATH" ]]; then
  printf '{"status": "error", "message": "File already exists. Use overwrite=true to overwrite.", "output_path": "%s"}\n' \
    "$OUTPUT_PATH"
  exit 1
fi

# Ensure parent directory exists
mkdir -p "$(dirname "$OUTPUT_PATH")"

# Write ASS template with variable interpolation
cat > "$OUTPUT_PATH" <<EOF
[Script Info]
Title: ${TITLE}
ScriptType: v4.00+
WrapStyle: 0
ScaledBorderAndShadow: yes
PlayResX: ${PLAY_RES_X}
PlayResY: ${PLAY_RES_Y}

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Microsoft YaHei,60,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,50,1
Style: Title,Microsoft YaHei,80,&H0000A5FF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,3,2,8,10,10,30,1
Style: Note,Microsoft YaHei,40,&H00CCCCCC,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,1,1,3,10,10,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,Hello World
Dialogue: 0,0:00:05.00,0:00:10.00,Title,,0,0,0,,{\an8}Sample Title
Dialogue: 0,0:00:05.00,0:00:10.00,Note,,0,0,0,,{\an3}Sample Note
EOF

printf '{"output_path": "%s", "title": "%s", "play_res_x": %s, "play_res_y": %s, "styles": ["Default", "Title", "Note"], "status": "created"}\n' \
  "$OUTPUT_PATH" "$TITLE" "$PLAY_RES_X" "$PLAY_RES_Y"
