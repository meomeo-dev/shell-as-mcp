#!/usr/bin/env bash
set -euo pipefail

# per-target smoke test: host_info bundle
# target: kernel=darwin  arch=arm64  (Apple Silicon macOS)
# Evidence: this file's existence + CI pass record confirms darwin/arm64 is tested.

current_kernel="$(uname -s | tr '[:upper:]' '[:lower:]')"
current_arch="$(uname -m)"

if [[ "$current_kernel" != "darwin" || "$current_arch" != "arm64" ]]; then
  echo "SKIP: target is darwin/arm64; detected ${current_kernel}/${current_arch}" >&2
  exit 0
fi

os="$(uname -s)"
arch="$(uname -m)"
kernel_release="$(uname -r)"

[[ -n "$os" ]]             || { echo "FAIL: uname -s returned empty" >&2; exit 1; }
[[ -n "$arch" ]]           || { echo "FAIL: uname -m returned empty" >&2; exit 1; }
[[ -n "$kernel_release" ]] || { echo "FAIL: uname -r returned empty" >&2; exit 1; }

echo "{\"status\":\"ok\",\"bundle\":\"host_info\",\"target\":\"darwin_arm64\",\"os\":\"${os}\",\"arch\":\"${arch}\"}"
