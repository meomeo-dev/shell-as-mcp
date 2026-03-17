#!/usr/bin/env bash
set -euo pipefail

package_name="${TOOL_PACKAGE_NAME:?TOOL_PACKAGE_NAME environment variable is required}"
cask="${TOOL_CASK:-false}"
force="${TOOL_FORCE:-false}"
confirm_action="${TOOL_CONFIRM_ACTION:-false}"

# --- Security: validate package name ---
if ! [[ "$package_name" =~ ^[a-zA-Z0-9@._+/-]+$ ]]; then
  printf 'ERROR: Invalid package name "%s". Only alphanumeric characters and @._+/- are allowed.\n' \
    "$package_name" >&2
  exit 1
fi

# --- Layer 1: LLM Guard ---
if [[ "$confirm_action" != "true" ]]; then
  printf 'ERROR: confirm_action must be true to authorize brew uninstall. Set confirm_action=true only after the user explicitly confirms this uninstallation.\n' >&2
  exit 1
fi

# --- Layer 2: macOS Native Authorization Dialog ---
os_name="$(uname -s)"
if [[ "$os_name" == "Darwin" ]]; then
  brew_display_cmd="brew uninstall"
  if [[ "$cask" == "true" ]]; then
    brew_display_cmd="brew uninstall --cask"
  fi

  dialog_script="display dialog \"Authorize: ${brew_display_cmd} ${package_name}\" buttons {\"Cancel\", \"Authorize\"} default button \"Authorize\" with title \"Homebrew Authorization Required\""

  if ! osascript -e "$dialog_script" > /dev/null 2>&1; then
    printf 'Authorization canceled by user.\n' >&2
    exit 1
  fi
fi

# --- Execute brew uninstall ---
declare -a brew_args=()
if [[ "$cask" == "true" ]]; then
  brew_args+=("--cask")
fi
if [[ "$force" == "true" ]]; then
  brew_args+=("--force")
fi

HOMEBREW_NO_ENV_HINTS=1 brew uninstall "${brew_args[@]+"${brew_args[@]}"}" "$package_name"
