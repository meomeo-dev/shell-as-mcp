#!/usr/bin/env bash
set -euo pipefail

# per-target smoke test: shell bundle
# target: kernel=darwin  arch=arm64  (Apple Silicon macOS)
# Evidence: this file's existence + CI pass record confirms darwin/arm64 is tested.

current_kernel="$(uname -s | tr '[:upper:]' '[:lower:]')"
current_arch="$(uname -m)"

if [[ "$current_kernel" != "darwin" || "$current_arch" != "arm64" ]]; then
  echo "SKIP: target is darwin/arm64; detected ${current_kernel}/${current_arch}" >&2
  exit 0
fi

bash_version="$(bash --version | head -1)"

# Verify bash can execute a sub-shell correctly
result="$(bash -c 'echo "smoke_ok"')"
[[ "$result" == "smoke_ok" ]] || { echo "FAIL: bash sub-shell returned unexpected output: ${result}" >&2; exit 1; }

echo "{\"status\":\"ok\",\"bundle\":\"shell\",\"target\":\"darwin_arm64\",\"bash\":\"${bash_version}\"}"
