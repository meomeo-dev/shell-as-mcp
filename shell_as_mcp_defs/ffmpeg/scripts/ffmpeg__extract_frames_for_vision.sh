#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${TOOL_OUTPUT_DIR:?output_dir is required via output_dir, FFMPEG_OUTPUT_DIR, or SHELL_AS_MCP_OUTPUT_DIR}"
export OUTPUT_DIR
mkdir -p "$OUTPUT_DIR"
cmd=(ffmpeg -hide_banner -loglevel error -y)

if [ -n "${START_TIME:-}" ]; then
  cmd+=( -ss "$START_TIME" )
fi
if [ -n "${END_TIME:-}" ]; then
  cmd+=( -to "$END_TIME" )
fi

cmd+=( -i "$INPUT_PATH" )

filters=()
if [ "${KEYFRAMES_ONLY:-false}" = "true" ]; then
  filters+=( "select='eq(pict_type\\,I)'" )
fi
if [ -n "${FPS:-}" ]; then
  filters+=( "fps=${FPS}" )
fi
if [ -n "${MAX_RESOLUTION:-}" ]; then
  filters+=( "scale='if(gt(iw,ih),min(${MAX_RESOLUTION},iw),-2)':'if(gt(iw,ih),-2,min(${MAX_RESOLUTION},ih))'" )
fi

if [ ${#filters[@]} -gt 0 ]; then
  IFS=,
  vf_chain="${filters[*]}"
  unset IFS
  cmd+=( -vf "$vf_chain" )
fi

if [ "${KEYFRAMES_ONLY:-false}" = "true" ]; then
  cmd+=( -vsync vfr )
fi

cmd+=( -q:v 2 "$OUTPUT_DIR/frame_%06d.jpg" )
"${cmd[@]}"

node -e 'const fs=require("fs");const path=require("path");const dir=process.env.OUTPUT_DIR;const files=fs.readdirSync(dir).filter((f)=>/^frame_\d+\.jpg$/.test(f)).sort().map((f)=>path.join(dir,f));console.log(JSON.stringify({output_dir:dir,frame_count:files.length,frame_paths:files}))'
