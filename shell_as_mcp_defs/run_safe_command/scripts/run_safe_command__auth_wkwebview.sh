#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "usage: $0 <request_id> <command> <args_json> <working_dir> <context_digest> <expires_at_ms>" >&2
  exit 12
fi

request_id="$1"
command_name="$2"
args_json="$3"
working_dir="$4"
context_digest="$5"
expires_at_ms="$6"

current_kernel="$(uname -s | tr '[:upper:]' '[:lower:]')"
current_arch="$(uname -m)"
if [[ "$current_kernel" != "darwin" || "$current_arch" != "arm64" ]]; then
  exit 12
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
swift_src="$script_dir/../native_auth/run_safe_command__auth_wkwebview.swift"
if [[ ! -f "$swift_src" ]]; then
  exit 12
fi

widget_dir="$script_dir/../widget"
if [[ ! -f "$widget_dir/index.html" ]]; then
  exit 12
fi

cache_dir="${TMPDIR:-/tmp}/mcp-shell-run-safe-command"
mkdir -p "$cache_dir"
compiled_bin="$cache_dir/run_safe_command__auth_wkwebview"

if [[ ! -x "$compiled_bin" || "$swift_src" -nt "$compiled_bin" ]]; then
  if ! command -v swiftc >/dev/null 2>&1; then
    exit 12
  fi
  swiftc -O -framework AppKit -framework WebKit "$swift_src" -o "$compiled_bin" || exit 12
fi

exec "$compiled_bin" "$request_id" "$command_name" "$args_json" "$working_dir" "$context_digest" "$expires_at_ms" "$widget_dir"
