#!/usr/bin/env bash
set -euo pipefail

# smoke test for shell bundle
# bash is always available (this script runs in bash)

bash_version="$(bash --version | head -1)"

# Verify bash can execute a sub-shell correctly
result="$(bash -c 'echo "smoke_ok"')"
[[ "$result" == "smoke_ok" ]] || { echo "FAIL: bash sub-shell returned unexpected output: ${result}" >&2; exit 1; }

echo "{\"status\":\"ok\",\"bundle\":\"shell\",\"bash\":\"${bash_version}\"}"
