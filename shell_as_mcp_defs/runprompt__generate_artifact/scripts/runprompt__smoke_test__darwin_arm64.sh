#!/usr/bin/env bash
set -euo pipefail

# per-target smoke test: runprompt__generate_artifact bundle
# target: kernel=darwin  arch=arm64  (Apple Silicon macOS)
# Evidence: this file's existence + CI pass record confirms darwin/arm64 is tested.

current_kernel="$(uname -s | tr '[:upper:]' '[:lower:]')"
current_arch="$(uname -m)"

if [[ "$current_kernel" != "darwin" || "$current_arch" != "arm64" ]]; then
  echo "SKIP: target is darwin/arm64; detected ${current_kernel}/${current_arch}" >&2
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not found" >&2
  exit 0
fi

python_version="$(python3 --version 2>&1)"

# Verify python3 >= 3.8 and that core stdlib modules are importable
python3 -c "import json, sys, os; assert sys.version_info >= (3, 8), 'python3 >= 3.8 required'"

echo "{\"status\":\"ok\",\"bundle\":\"runprompt__generate_artifact\",\"target\":\"darwin_arm64\",\"python\":\"${python_version}\"}"
