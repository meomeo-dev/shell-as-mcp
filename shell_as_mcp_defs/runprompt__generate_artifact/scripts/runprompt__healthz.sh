#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"
reasons=()

if ! command -v python3 >/dev/null 2>&1; then
  reasons+=("missing command: python3")
fi
if ! command -v node >/dev/null 2>&1; then
  reasons+=("missing command: node (required by mcp_filesystem_bridge.mjs)")
fi
if [[ ! -f "$script_dir/runprompt_generate_artifact.py" ]]; then
  reasons+=("missing file: runprompt_generate_artifact.py")
fi
if [[ ! -f "$script_dir/runprompt_tools.py" ]]; then
  reasons+=("missing file: runprompt_tools.py")
fi
if [[ ! -f "$script_dir/mcp_filesystem_bridge.mjs" ]]; then
  reasons+=("missing file: mcp_filesystem_bridge.mjs")
fi
if [[ ! -f "$script_dir/sandbox_exec.mjs" ]]; then
  reasons+=("missing file: sandbox_exec.mjs")
fi

if [[ "${#reasons[@]}" -gt 0 ]]; then
  reason_text="$(printf '%s; ' "${reasons[@]}")"
  reason_text="${reason_text%; }"
  echo "{\"status\":\"error\",\"bundle\":\"runprompt__generate_artifact\",\"tool\":\"runprompt__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\",\"message\":\"dependencies not ready: ${reason_text}\"}"
  exit 1
fi

python_version="$(python3 --version 2>&1)"
echo "{\"status\":\"ok\",\"bundle\":\"runprompt__generate_artifact\",\"tool\":\"runprompt__healthz\",\"kernel\":\"${kernel}\",\"arch\":\"${arch}\",\"python\":\"${python_version}\"}"
