#!/usr/bin/env bash
set -euo pipefail

probe_args=(-v error -print_format json -show_format -show_streams)

case "${STREAM_TYPE:-all}" in
  video) probe_args+=(-select_streams v) ;;
  audio) probe_args+=(-select_streams a) ;;
  *) ;;
esac

ffprobe "${probe_args[@]}" "$INPUT_PATH"
