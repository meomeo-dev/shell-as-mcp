#!/usr/bin/env bash
set -euo pipefail

sample_rate="${SAMPLE_RATE:-16000}"
channels="${CHANNELS:-1}"
remove_silence="${REMOVE_SILENCE:-true}"
audio_format="${AUDIO_FORMAT:-mp3}"

cmd=(ffmpeg -hide_banner -loglevel error -y)

if [ -n "${START_TIME:-}" ]; then
  cmd+=( -ss "$START_TIME" )
fi
if [ -n "${END_TIME:-}" ]; then
  cmd+=( -to "$END_TIME" )
fi

cmd+=( -i "$INPUT_PATH" -vn -ar "$sample_rate" -ac "$channels" )

if [ "$remove_silence" = "true" ]; then
  cmd+=( -af "silenceremove=start_periods=1:start_duration=0.3:start_threshold=-45dB:stop_periods=-1:stop_duration=0.5:stop_threshold=-45dB" )
fi

cmd+=( -f "$audio_format" "$OUTPUT_PATH" )
"${cmd[@]}"

node -e 'console.log(JSON.stringify({output_path: process.env.OUTPUT_PATH, start_time: process.env.START_TIME || null, end_time: process.env.END_TIME || null, sample_rate: Number(process.env.SAMPLE_RATE || 16000), channels: Number(process.env.CHANNELS || 1), remove_silence: (process.env.REMOVE_SILENCE || "true") === "true", audio_format: process.env.AUDIO_FORMAT || "mp3"}))'
