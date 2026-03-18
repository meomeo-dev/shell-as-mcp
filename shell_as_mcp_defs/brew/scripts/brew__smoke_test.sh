#!/usr/bin/env bash
set -euo pipefail

# smoke test for brew bundle
# exit 0 = PASS or SKIP; exit 1 = FAIL

if ! command -v brew >/dev/null 2>&1; then
  echo "SKIP: brew not found (not macOS or brew not installed)" >&2
  exit 0
fi

brew_version_full="$(brew --version 2>&1)"
brew_version="${brew_version_full%%$'\n'*}"

# Verify package list is accessible (no crash)
brew list --versions >/dev/null 2>&1

echo "{\"status\":\"ok\",\"bundle\":\"brew\",\"brew\":\"${brew_version}\"}"
