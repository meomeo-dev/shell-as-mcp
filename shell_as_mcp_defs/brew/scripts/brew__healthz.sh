#!/usr/bin/env bash
set -euo pipefail

kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"
reasons=()

if ! command -v brew >/dev/null 2>&1; then
  reasons+=("missing command: brew")
fi
if ! command -v python3 >/dev/null 2>&1; then
  reasons+=("missing command: python3 (required by brew search/list scripts)")
fi

if [[ "${#reasons[@]}" -gt 0 ]]; then
  reason_text="$(printf '%s; ' "${reasons[@]}")"
  reason_text="${reason_text%; }"
  echo "{\"status\":\"error\",\"bundle\":\"brew\",\"tool\":\"brew__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\",\"message\":\"dependencies not ready: ${reason_text}\"}"
  exit 1
fi

brew_version="$(brew --version)"
brew_version="${brew_version%%$'\n'*}"
echo "{\"status\":\"ok\",\"bundle\":\"brew\",\"tool\":\"brew__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\",\"brew\":\"${brew_version}\"}"
