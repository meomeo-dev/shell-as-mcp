#!/usr/bin/env bash
set -euo pipefail

package_name="${TOOL_PACKAGE_NAME:?TOOL_PACKAGE_NAME environment variable is required}"
cask="${TOOL_CASK:-false}"
confirm_action="${TOOL_CONFIRM_ACTION:-false}"

# --- Security: validate package name ---
if ! [[ "$package_name" =~ ^[a-zA-Z0-9@._+/-]+$ ]]; then
  printf 'ERROR: Invalid package name "%s". Only alphanumeric characters and @._+/- are allowed.\n' \
    "$package_name" >&2
  exit 1
fi

# --- Layer 1: LLM Guard ---
if [[ "$confirm_action" != "true" ]]; then
  printf 'ERROR: confirm_action must be true to authorize brew upgrade. Set confirm_action=true only after the user explicitly confirms this upgrade.\n' >&2
  exit 1
fi

# --- Layer 2: macOS Native Authorization Dialog ---
os_name="$(uname -s)"
if [[ "$os_name" == "Darwin" ]]; then
  brew_display_cmd="brew upgrade"
  if [[ "$cask" == "true" ]]; then
    brew_display_cmd="brew upgrade --cask"
  fi

  dialog_script="display dialog \"Authorize: ${brew_display_cmd} ${package_name}\" buttons {\"Cancel\", \"Authorize\"} default button \"Authorize\" with title \"Homebrew Authorization Required\""

  if ! osascript -e "$dialog_script" > /dev/null 2>&1; then
    printf 'Authorization canceled by user.\n' >&2
    exit 1
  fi
fi

# --- Execute brew upgrade ---
if [[ "$cask" == "true" ]]; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew upgrade --cask "$package_name"
else
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew upgrade "$package_name"
fi
