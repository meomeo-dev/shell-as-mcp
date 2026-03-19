#!/usr/bin/env bash
set -euo pipefail

kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"
reasons=()

if ! command -v uname >/dev/null 2>&1; then
  reasons+=("missing command: uname")
fi
if ! command -v python3 >/dev/null 2>&1; then
  reasons+=("missing command: python3 (required by host_info context aggregation)")
fi

if [[ "${#reasons[@]}" -gt 0 ]]; then
  reason_text="$(printf '%s; ' "${reasons[@]}")"
  reason_text="${reason_text%; }"
  echo "{\"status\":\"error\",\"bundle\":\"host_info\",\"tool\":\"host_info__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\",\"message\":\"dependencies not ready: ${reason_text}\"}"
  exit 1
fi

echo "{\"status\":\"ok\",\"bundle\":\"host_info\",\"tool\":\"host_info__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\"}"
