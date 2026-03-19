#!/usr/bin/env bash
set -euo pipefail

kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"
reasons=()

if ! command -v ffmpeg >/dev/null 2>&1; then
  reasons+=("missing command: ffmpeg")
fi

if [[ "${#reasons[@]}" -gt 0 ]]; then
  reason_text="$(printf '%s; ' "${reasons[@]}")"
  reason_text="${reason_text%; }"
  echo "{\"status\":\"error\",\"bundle\":\"advanced_substation_alpha_ass\",\"tool\":\"ass__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\",\"message\":\"dependencies not ready: ${reason_text}\"}"
  exit 1
fi

ffmpeg_version="$(ffmpeg -version)"
ffmpeg_version="${ffmpeg_version%%$'\n'*}"
echo "{\"status\":\"ok\",\"bundle\":\"advanced_substation_alpha_ass\",\"tool\":\"ass__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\",\"ffmpeg\":\"${ffmpeg_version}\"}"
