#!/usr/bin/env bash
set -euo pipefail

cask_only="${TOOL_CASK_ONLY:-false}"
formula_only="${TOOL_FORMULA_ONLY:-false}"

formula_list=""
cask_list=""

if [[ "$cask_only" != "true" ]]; then
  formula_list="$(brew list --formula --versions 2>/dev/null || true)"
fi

if [[ "$formula_only" != "true" ]]; then
  cask_list="$(brew list --cask --versions 2>/dev/null || true)"
fi

FORMULA_LIST="$formula_list" CASK_LIST="$cask_list" python3 -c '
import json, os

def parse_list(raw):
    entries = []
    for line in raw.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        entries.append({
            "name": parts[0],
            "version": parts[1] if len(parts) > 1 else None
        })
    return entries

formulae = parse_list(os.environ.get("FORMULA_LIST", ""))
casks = parse_list(os.environ.get("CASK_LIST", ""))
print(json.dumps({
    "formulae": formulae,
    "casks": casks,
    "formula_count": len(formulae),
    "cask_count": len(casks)
}, indent=2))
'
