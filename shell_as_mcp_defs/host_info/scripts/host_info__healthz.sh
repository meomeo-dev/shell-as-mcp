#!/usr/bin/env bash
set -euo pipefail

if ! command -v uname >/dev/null 2>&1; then
  echo '{"status":"error","bundle":"host_info","message":"uname not found"}'
  exit 1
fi

os_name="$(uname -s)"
echo "{\"status\":\"ok\",\"bundle\":\"host_info\",\"tool\":\"host_info__healthz\",\"os\":\"${os_name}\"}"
