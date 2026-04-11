#!/usr/bin/env bash
set -euo pipefail

kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"

if [[ "$kernel" != "darwin" || "$arch" != "arm64" ]]; then
  echo "SKIP: iwencai darwin_arm64 smoke only runs on Apple Silicon macOS" >&2
  exit 0
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
exec bash "$script_dir/iwencai__smoke_test.sh"
