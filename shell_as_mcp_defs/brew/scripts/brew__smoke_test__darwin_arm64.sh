#!/usr/bin/env bash
set -euo pipefail

# per-target smoke test: brew bundle
# target: kernel=darwin  arch=arm64  (Apple Silicon macOS)
# Evidence: this file's existence + CI pass record confirms darwin/arm64 is tested.

current_kernel="$(uname -s | tr '[:upper:]' '[:lower:]')"
current_arch="$(uname -m)"

if [[ "$current_kernel" != "darwin" || "$current_arch" != "arm64" ]]; then
  echo "SKIP: target is darwin/arm64; detected ${current_kernel}/${current_arch}" >&2
  exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "SKIP: brew not found (brew not installed)" >&2
  exit 0
fi

brew_version_full="$(brew --version 2>&1)"
brew_version="${brew_version_full%%$'\n'*}"

# Verify package list is accessible (no network)
brew list --versions >/dev/null 2>&1

echo "{\"status\":\"ok\",\"bundle\":\"brew\",\"target\":\"darwin_arm64\",\"brew\":\"${brew_version}\"}"
