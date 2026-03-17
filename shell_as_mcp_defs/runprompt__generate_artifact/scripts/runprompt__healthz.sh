#!/usr/bin/env bash
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo '{"status":"error","bundle":"runprompt__generate_artifact","message":"python3 not found"}'
  exit 1
fi

python_version="$(python3 --version 2>&1)"
echo "{\"status\":\"ok\",\"bundle\":\"runprompt__generate_artifact\",\"tool\":\"runprompt__healthz\",\"python\":\"${python_version}\"}"
