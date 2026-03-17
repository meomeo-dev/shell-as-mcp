#!/usr/bin/env bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo '{"status":"error","bundle":"brew","message":"brew not found"}'
  exit 1
fi

brew_version="$(brew --version)"
brew_version="${brew_version%%$'\n'*}"
echo "{\"status\":\"ok\",\"bundle\":\"brew\",\"tool\":\"brew__healthz\",\"brew\":\"${brew_version}\"}"
