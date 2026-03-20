#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:?output_dir is required via output_dir param, FFMPEG_OUTPUT_DIR, or SHELL_AS_MCP_OUTPUT_DIR}"
mkdir -p "$OUTPUT_DIR"

# shellcheck disable=SC2016
node -e '
const {execFileSync} = require("child_process");
const path = require("path");

const inputPath = process.env.INPUT_PATH;
const outputDir = process.env.OUTPUT_DIR;
const prefix = process.env.OUTPUT_PREFIX || "segment";
const reencode = (process.env.REENCODE || "false") === "true";
const splitPoints = (process.env.SPLIT_POINTS || "").split(",").map(s => s.trim()).filter(Boolean);

if (splitPoints.length === 0) {
  process.stderr.write("split_points must contain at least one timestamp.\n");
  process.exit(1);
}

const starts = [null, ...splitPoints];
const ends = [...splitPoints, null];
const segments = [];

for (let i = 0; i < starts.length; i++) {
  const outFile = path.join(outputDir, `${prefix}_${String(i).padStart(3, "0")}.mp4`);
  const cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"];
  if (starts[i] !== null) { cmd.push("-ss", starts[i]); }
  if (ends[i] !== null) { cmd.push("-to", ends[i]); }
  cmd.push("-i", inputPath);
  if (reencode) {
    cmd.push("-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-c:a", "aac", "-b:a", "128k");
  } else {
    cmd.push("-c", "copy");
  }
  cmd.push(outFile);
  execFileSync(cmd[0], cmd.slice(1), {stdio: ["ignore", "inherit", "inherit"]});
  segments.push(outFile);
}

console.log(JSON.stringify({
  output_dir: outputDir,
  segment_count: segments.length,
  segments
}));
'
