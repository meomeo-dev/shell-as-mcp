#!/usr/bin/env bash
set -euo pipefail

speed_factor="${SPEED_FACTOR:-1}"
strip_audio="${STRIP_AUDIO:-false}"
node -e 'const s=Number(process.env.SPEED_FACTOR || 1); if (!Number.isFinite(s) || s <= 0) { console.error("speed_factor must be > 0"); process.exit(1); }'

cmd=(ffmpeg -hide_banner -loglevel error -y)

if [ -n "${START_TIME:-}" ]; then
  cmd+=( -ss "$START_TIME" )
fi
if [ -n "${END_TIME:-}" ]; then
  cmd+=( -to "$END_TIME" )
fi

cmd+=( -i "$INPUT_PATH" )

filter_parts=()

if [ -n "${MAX_RESOLUTION:-}" ]; then
  filter_parts+=( "scale='if(gt(iw,ih),min(${MAX_RESOLUTION},iw),-2)':'if(gt(iw,ih),-2,min(${MAX_RESOLUTION},ih))'" )
fi

if [ -n "${FPS:-}" ]; then
  filter_parts+=( "fps=${FPS}" )
fi

if [ "$speed_factor" != "1" ]; then
  filter_parts+=( "setpts=PTS/${speed_factor}" )
fi

if [ -n "${WATERMARK_PATH:-}" ]; then
  cmd+=( -i "$WATERMARK_PATH" )
  filter_parts+=( "overlay=W-w-16:H-h-16" )
fi

if [ ${#filter_parts[@]} -gt 0 ]; then
  IFS=,
  filter_graph="${filter_parts[*]}"
  unset IFS
  cmd+=( -filter_complex "$filter_graph" )
fi

if [ "$strip_audio" = "true" ]; then
  cmd+=( -an )
elif [ "$speed_factor" != "1" ]; then
  # shellcheck disable=SC2016
  atempo_chain="$(node -e 'const speed=Number(process.env.SPEED_FACTOR || 1); let remaining=speed; const parts=[]; while (remaining > 2) { parts.push("atempo=2.0"); remaining /= 2; } while (remaining < 0.5) { parts.push("atempo=0.5"); remaining /= 0.5; } parts.push(`atempo=${remaining.toFixed(6).replace(/0+$/, "").replace(/\\.$/, "")}`); console.log(parts.join(","));')"
  cmd+=( -af "$atempo_chain" )
fi

cmd+=( "$OUTPUT_PATH" )
"${cmd[@]}"

# shellcheck disable=SC2016
node -e 'console.log(JSON.stringify({output_path: process.env.OUTPUT_PATH, start_time: process.env.START_TIME || null, end_time: process.env.END_TIME || null, max_resolution: process.env.MAX_RESOLUTION || null, fps: process.env.FPS || null, speed_factor: Number(process.env.SPEED_FACTOR || 1), strip_audio: (process.env.STRIP_AUDIO || "false") === "true", watermark_path: process.env.WATERMARK_PATH || null}))'
