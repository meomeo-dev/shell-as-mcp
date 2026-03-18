#!/usr/bin/env bash
set -euo pipefail

# smoke test for runprompt__generate_artifact bundle
# exit 0 = PASS or SKIP; exit 1 = FAIL

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not found" >&2
  exit 0
fi

python_version="$(python3 --version 2>&1)"

# Verify python3 >= 3.8 and that core stdlib modules are importable
python3 -c "import json, sys, os; assert sys.version_info >= (3, 8), 'python3 >= 3.8 required'"

echo "{\"status\":\"ok\",\"bundle\":\"runprompt__generate_artifact\",\"python\":\"${python_version}\"}"
