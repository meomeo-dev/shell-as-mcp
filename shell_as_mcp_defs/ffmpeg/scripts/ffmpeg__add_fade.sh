#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2016
node -e '
const s = Number(process.env.FADE_IN_DURATION || 0);
const e = Number(process.env.FADE_OUT_DURATION || 0);
if (s <= 0 && e <= 0) {
  process.stderr.write("fade_in_duration and fade_out_duration cannot both be 0 or negative.\n");
  process.exit(1);
}
'

duration_raw="$(ffprobe -v error -show_entries format=duration \
  -of default=nokey=1:noprint_wrappers=1 "$INPUT_PATH")"

# shellcheck disable=SC2016
node -e '
const {execFileSync} = require("child_process");

const fadeIn = Number(process.env.FADE_IN_DURATION || 0);
const fadeOut = Number(process.env.FADE_OUT_DURATION || 0);
const fadeColor = process.env.FADE_COLOR || "black";
const includeAudio = (process.env.INCLUDE_AUDIO || "true") === "true";
const duration = Number(process.argv[1]);

const vfParts = [];
const afParts = [];

if (fadeIn > 0) {
  vfParts.push(`fade=t=in:st=0:d=${fadeIn}:color=${fadeColor}`);
  if (includeAudio) { afParts.push(`afade=t=in:st=0:d=${fadeIn}`); }
}

if (fadeOut > 0) {
  const outStart = Math.max(0, duration - fadeOut).toFixed(3);
  vfParts.push(`fade=t=out:st=${outStart}:d=${fadeOut}:color=${fadeColor}`);
  if (includeAudio) { afParts.push(`afade=t=out:st=${outStart}:d=${fadeOut}`); }
}

const cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", process.env.INPUT_PATH];
if (vfParts.length > 0) { cmd.push("-vf", vfParts.join(",")); }
if (afParts.length > 0) { cmd.push("-af", afParts.join(",")); }
if (vfParts.length === 0) { cmd.push("-c:v", "copy"); }
cmd.push(process.env.OUTPUT_PATH);

execFileSync(cmd[0], cmd.slice(1), {stdio: ["ignore", "inherit", "inherit"]});

console.log(JSON.stringify({
  output_path: process.env.OUTPUT_PATH,
  fade_in_duration: fadeIn,
  fade_out_duration: fadeOut,
  fade_color: fadeColor,
  include_audio: includeAudio
}));
' "$duration_raw"
