#!/usr/bin/env bash
set -euo pipefail

package_name="${TOOL_PACKAGE_NAME:?TOOL_PACKAGE_NAME environment variable is required}"
cask="${TOOL_CASK:-false}"

if [[ "$cask" == "true" ]]; then
  brew info --cask --json=v2 "$package_name"
else
  brew info --json=v2 "$package_name"
fi
