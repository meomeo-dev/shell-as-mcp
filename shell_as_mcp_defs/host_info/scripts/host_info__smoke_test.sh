#!/usr/bin/env bash
set -euo pipefail

# smoke test for host_info bundle
# uname is POSIX-mandated; no SKIP branch needed

os="$(uname -s)"
arch="$(uname -m)"
kernel="$(uname -r)"

# Guard: all three values must be non-empty
[[ -n "$os" ]]     || { echo "FAIL: uname -s returned empty" >&2; exit 1; }
[[ -n "$arch" ]]   || { echo "FAIL: uname -m returned empty" >&2; exit 1; }
[[ -n "$kernel" ]] || { echo "FAIL: uname -r returned empty" >&2; exit 1; }

echo "{\"status\":\"ok\",\"bundle\":\"host_info\",\"os\":\"${os}\",\"arch\":\"${arch}\"}"
