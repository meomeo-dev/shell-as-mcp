#!/usr/bin/env bash
set -euo pipefail

query="${TOOL_QUERY:?TOOL_QUERY environment variable is required}"
include_casks="${TOOL_INCLUDE_CASKS:-true}"

formula_results=""
formula_results="$(brew search --formula "$query" 2>/dev/null || true)"

cask_results=""
if [[ "$include_casks" != "false" ]]; then
  cask_results="$(brew search --cask "$query" 2>/dev/null || true)"
fi

SEARCH_QUERY="$query" FORMULA_RESULTS="$formula_results" CASK_RESULTS="$cask_results" \
  python3 -c '
import json, os

def parse_brew_lines(raw):
    lines = raw.strip().split("\n") if raw.strip() else []
    return [
        l.strip() for l in lines
        if l.strip()
        and not l.startswith("==>")
        and "No formula" not in l
        and "No cask" not in l
    ]

formulae = parse_brew_lines(os.environ.get("FORMULA_RESULTS", ""))
casks = parse_brew_lines(os.environ.get("CASK_RESULTS", ""))
print(json.dumps({
    "query": os.environ.get("SEARCH_QUERY", ""),
    "formulae": formulae,
    "casks": casks,
    "total_count": len(formulae) + len(casks)
}, indent=2))
'
