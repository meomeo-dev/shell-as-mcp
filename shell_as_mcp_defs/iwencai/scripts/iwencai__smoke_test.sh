#!/usr/bin/env bash
set -euo pipefail

if ! command -v iwencai >/dev/null 2>&1; then
  echo "SKIP: iwencai command not found" >&2
  exit 0
fi

iwencai --help >/dev/null 2>&1
iwencai query2data --help >/dev/null 2>&1
iwencai search --help >/dev/null 2>&1
iwencai skillbook --help >/dev/null 2>&1

echo "{\"status\":\"ok\",\"bundle\":\"iwencai\",\"checked\":[\"iwencai --help\",\"iwencai query2data --help\",\"iwencai search --help\",\"iwencai skillbook --help\"]}"
