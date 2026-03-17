#!/usr/bin/env bash
set -euo pipefail

if ! command -v bash >/dev/null 2>&1; then
  echo '{"status":"error","bundle":"shell","message":"bash not found"}'
  exit 1
fi

echo '{"status":"ok","bundle":"shell","tool":"shell__healthz"}'
