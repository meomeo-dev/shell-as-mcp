#!/usr/bin/env bash
set -euo pipefail

kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"

if ! command -v iwencai >/dev/null 2>&1; then
  echo "{\"status\":\"error\",\"bundle\":\"iwencai\",\"tool\":\"iwencai__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\",\"message\":\"missing command: iwencai\"}"
  exit 1
fi

iwencai_path="$(command -v iwencai)"
api_key_configured="false"
if [[ -n "${TOOL_IWENCAI_API_KEY:-}" ]]; then
  api_key_configured="true"
fi

echo "{\"status\":\"ok\",\"bundle\":\"iwencai\",\"tool\":\"iwencai__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\",\"iwencai_path\":\"${iwencai_path}\",\"api_key_configured\":${api_key_configured}}"
