#!/usr/bin/env bash
set -euo pipefail

current_kernel="$(uname -s | tr '[:upper:]' '[:lower:]')"
current_arch="$(uname -m)"
script_dir="$(cd "$(dirname "$0")" && pwd)"

target_script="$script_dir/run_safe_command__smoke_test.sh"

if [[ "$current_kernel" != "darwin" || "$current_arch" != "arm64" ]]; then
  echo "SKIP: target is darwin/arm64; detected ${current_kernel}/${current_arch}" >&2
  exit 0
fi

bash "$target_script"
