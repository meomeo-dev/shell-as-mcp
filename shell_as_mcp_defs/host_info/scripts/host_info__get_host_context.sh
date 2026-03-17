#!/usr/bin/env bash
set -euo pipefail

include_hardware="${TOOL_INCLUDE_HARDWARE:-true}"
filter_raw="${TOOL_FILTER_TOOLS:-}"
output_format="${TOOL_OUTPUT_FORMAT:-pretty}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 1  System info
# ═══════════════════════════════════════════════════════════════════════════════

os_name="$(uname -s)"
os_release="$(uname -r)"
machine_arch="$(uname -m)"

# macOS-specific version info
macos_product_name=""
macos_version=""
macos_build=""
if [[ "$os_name" == "Darwin" ]]; then
  macos_product_name="$(sw_vers -productName 2>/dev/null || true)"
  macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
  macos_build="$(sw_vers -buildVersion 2>/dev/null || true)"
fi

# Linux distro info (grep only, no source)
linux_distro_name=""
linux_distro_id=""
linux_distro_version=""
if [[ -f /etc/os-release ]]; then
  linux_distro_id="$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
  linux_distro_version="$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
  linux_distro_name="$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"' || true)"
fi

# Time
current_datetime="$(date '+%Y-%m-%dT%H:%M:%S')"
utc_offset="$(date '+%z')"

# Locale: language + region
locale_val="${LANG:-${LC_ALL:-}}"
language="${locale_val%%_*}"
language="${language%%.*}"
locale_country="${locale_val#*_}"
region="${locale_country%%.*}"

# Timezone
timezone=""
if [[ -L /etc/localtime ]]; then
  tz_link="$(readlink /etc/localtime)"
  timezone="${tz_link#*/zoneinfo/}"
fi
if [[ -z "$timezone" ]]; then
  timezone="${TZ:-$(date '+%Z')}"
fi

# User and shell
user_name="${USER:-$(id -un 2>/dev/null || true)}"
home_dir="${HOME:-}"
shell_val="${SHELL:-}"

# Hardware (optional)
cpu_count=""
total_mem_bytes=""
if [[ "$include_hardware" != "false" ]]; then
  if command -v nproc > /dev/null 2>&1; then
    cpu_count="$(nproc)"
  elif command -v sysctl > /dev/null 2>&1; then
    cpu_count="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  fi

  if [[ "$os_name" == "Darwin" ]] && command -v sysctl > /dev/null 2>&1; then
    total_mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
  elif [[ -f /proc/meminfo ]]; then
    total_mem_bytes="$(awk '/^MemTotal:/{print $2 * 1024; exit}' /proc/meminfo 2>/dev/null || true)"
  fi
fi

# Write system section to temp file
OS_NAME="$os_name" \
OS_RELEASE="$os_release" \
MACHINE_ARCH="$machine_arch" \
MACOS_PRODUCT_NAME="$macos_product_name" \
MACOS_VERSION="$macos_version" \
MACOS_BUILD="$macos_build" \
LINUX_DISTRO_NAME="$linux_distro_name" \
LINUX_DISTRO_ID="$linux_distro_id" \
LINUX_DISTRO_VERSION="$linux_distro_version" \
CURRENT_DATETIME="$current_datetime" \
UTC_OFFSET="$utc_offset" \
LANGUAGE_CODE="$language" \
REGION_CODE="$region" \
LOCALE_VAL="$locale_val" \
TIMEZONE_VAL="$timezone" \
USER_NAME="$user_name" \
HOME_DIR="$home_dir" \
SHELL_VAL="$shell_val" \
CPU_COUNT="$cpu_count" \
TOTAL_MEM_BYTES="$total_mem_bytes" \
python3 -c '
import json, os

def ev(k):
    v = os.environ.get(k, "")
    return v if v else None

def ev_int(k):
    v = os.environ.get(k, "")
    return int(v) if v and v.isdigit() else None

out = {
    "os_name": ev("OS_NAME"),
    "os_release": ev("OS_RELEASE"),
    "machine_arch": ev("MACHINE_ARCH"),
    "macos_product_name": ev("MACOS_PRODUCT_NAME"),
    "macos_version": ev("MACOS_VERSION"),
    "macos_build": ev("MACOS_BUILD"),
    "linux_distro_name": ev("LINUX_DISTRO_NAME"),
    "linux_distro_id": ev("LINUX_DISTRO_ID"),
    "linux_distro_version": ev("LINUX_DISTRO_VERSION"),
    "language": ev("LANGUAGE_CODE"),
    "region": ev("REGION_CODE"),
    "locale": ev("LOCALE_VAL"),
    "timezone": ev("TIMEZONE_VAL"),
    "current_datetime": ev("CURRENT_DATETIME"),
    "utc_offset": ev("UTC_OFFSET"),
    "user": ev("USER_NAME"),
    "home_dir": ev("HOME_DIR"),
    "shell": ev("SHELL_VAL"),
    "cpu_count": ev_int("CPU_COUNT"),
    "total_mem_bytes": ev_int("TOTAL_MEM_BYTES"),
}
print(json.dumps(out))
' > "$tmp_dir/system.json"

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 2  Dev environments
# ═══════════════════════════════════════════════════════════════════════════════

filter_cleaned="${filter_raw// /}"

# Returns 0 if tool should be checked given the current filter setting.
should_check() {
  local tool="$1"
  if [[ -z "$filter_cleaned" ]]; then
    return 0
  fi
  if printf '%s' ",$filter_cleaned," | grep -qF ",$tool,"; then
    return 0
  fi
  return 1
}

declare -a results=()

# check_tool <tool_name> [version_arg1 version_arg2 ...]
check_tool() {
  local tool_name
  tool_name="$1"
  shift
  local version_args=("$@")

  if ! should_check "$tool_name"; then
    return 0
  fi

  local tool_path
  if ! tool_path="$(command -v "$tool_name" 2>/dev/null)"; then
    local json
    json="$(TOOL_N="$tool_name" python3 -c '
import json, os
print(json.dumps({"tool": os.environ["TOOL_N"], "available": False, "path": None, "version": None}))
')"
    results+=("$json")
    return 0
  fi

  local version_raw=""
  if [[ ${#version_args[@]} -gt 0 ]]; then
    version_raw="$("$tool_name" "${version_args[@]}" 2>&1 | head -1)" || version_raw=""
  fi

  local json
  json="$(TOOL_N="$tool_name" TOOL_P="$tool_path" TOOL_V="$version_raw" python3 -c '
import json, os
print(json.dumps({
  "tool": os.environ["TOOL_N"],
  "available": True,
  "path": os.environ["TOOL_P"],
  "version": os.environ["TOOL_V"]
}))
')"
  results+=("$json")
}

# ── Python ────────────────────────────────────────────────────────────────────
check_tool python3 --version
check_tool python --version
check_tool pip3 --version
check_tool uv --version
check_tool poetry --version

# ── Node.js ───────────────────────────────────────────────────────────────────
check_tool node --version
check_tool npm --version
check_tool npx --version
check_tool yarn --version
check_tool pnpm --version
check_tool bun --version
check_tool deno --version

# ── TypeScript ────────────────────────────────────────────────────────────────
check_tool tsc --version

# ── Rust ──────────────────────────────────────────────────────────────────────
check_tool rustc --version
check_tool cargo --version
check_tool rustup --version

# ── Java / JVM ────────────────────────────────────────────────────────────────
check_tool java -version
check_tool javac -version
check_tool mvn --version
check_tool gradle --version
check_tool kotlin -version

# ── Ruby ──────────────────────────────────────────────────────────────────────
check_tool ruby --version
check_tool gem --version
check_tool bundle --version

# ── Go ────────────────────────────────────────────────────────────────────────
check_tool go version

# ── PHP ───────────────────────────────────────────────────────────────────────
check_tool php --version

# ── Swift ─────────────────────────────────────────────────────────────────────
check_tool swift --version

# ── .NET ──────────────────────────────────────────────────────────────────────
check_tool dotnet --version

# ── Build / VCS ───────────────────────────────────────────────────────────────
check_tool git --version
check_tool make --version
check_tool cmake --version

# ── Container ─────────────────────────────────────────────────────────────────
check_tool docker --version
check_tool kubectl version --client

# Write dev_environments section to temp file
if [[ ${#results[@]} -eq 0 ]]; then
  printf '{"tools":[],"available_count":0,"total_checked":0}' > "$tmp_dir/dev.json"
else
  python3 -c '
import sys, json

lines = sys.stdin.read().strip().split("\n")
items = [json.loads(line) for line in lines if line.strip()]
avail = sum(1 for i in items if i.get("available"))
print(json.dumps({
  "tools": items,
  "available_count": avail,
  "total_checked": len(items)
}))
' <<< "$(printf '%s\n' "${results[@]}")" > "$tmp_dir/dev.json"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 3  Combine and emit final JSON
# ═══════════════════════════════════════════════════════════════════════════════

OUTPUT_FORMAT="$output_format" \
SYSTEM_JSON_FILE="$tmp_dir/system.json" \
DEV_JSON_FILE="$tmp_dir/dev.json" \
python3 -c '
import json, os

with open(os.environ["SYSTEM_JSON_FILE"]) as f:
    system = json.load(f)
with open(os.environ["DEV_JSON_FILE"]) as f:
    dev = json.load(f)

indent = 2 if os.environ.get("OUTPUT_FORMAT", "pretty") != "compact" else None
print(json.dumps({"system": system, "dev_environments": dev}, indent=indent))
'
