#!/usr/bin/env bash
set -euo pipefail

input_value="${1:-}"
prefix="${SCRIPT_PREFIX:-script}"

printf '%s:%s\n' "${prefix}" "${input_value}"
