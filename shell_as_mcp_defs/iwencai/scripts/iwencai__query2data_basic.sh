#!/usr/bin/env bash
set -euo pipefail

query="${TOOL_QUERY:?TOOL_QUERY environment variable is required}"
limit="${TOOL_LIMIT:-20}"
page="${TOOL_PAGE:-1}"
format="${TOOL_FORMAT:-json}"
api_key="${TOOL_IWENCAI_API_KEY:?TOOL_IWENCAI_API_KEY environment variable is required}"

if [[ "$query" == *$'\n'* || "$query" == *$'\r'* ]]; then
  echo "query must be a single-line string" >&2
  exit 2
fi

case "$format" in
  json|jsonl) ;;
  *)
    echo "format must be one of: json, jsonl" >&2
    exit 2
    ;;
esac

case "$limit" in
  ''|*[!0-9]*)
    echo "limit must be a positive integer" >&2
    exit 2
    ;;
esac

case "$page" in
  ''|*[!0-9]*)
    echo "page must be a positive integer" >&2
    exit 2
    ;;
esac

if (( limit < 1 || limit > 50 )); then
  echo "limit must be between 1 and 50" >&2
  exit 2
fi

if (( page < 1 || page > 100 )); then
  echo "page must be between 1 and 100" >&2
  exit 2
fi

exec iwencai query2data \
  --query "$query" \
  --limit "$limit" \
  --page "$page" \
  --format "$format" \
  --api-key "$api_key"
