#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"
reasons=()

if ! command -v bash >/dev/null 2>&1; then
  reasons+=("missing command: bash")
fi
if [[ ! -f "$script_dir/echo_script.sh" ]]; then
  reasons+=("missing file: echo_script.sh")
fi

if [[ "${#reasons[@]}" -gt 0 ]]; then
  reason_text="$(printf '%s; ' "${reasons[@]}")"
  reason_text="${reason_text%; }"
  echo "{\"status\":\"error\",\"bundle\":\"shell\",\"tool\":\"shell__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\",\"message\":\"dependencies not ready: ${reason_text}\"}"
  exit 1
fi

echo "{\"status\":\"ok\",\"bundle\":\"shell\",\"tool\":\"shell__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\"}"
