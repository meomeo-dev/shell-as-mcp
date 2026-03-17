#!/usr/bin/env bash
set -euo pipefail

artifact_type="${1:-}"
requirements="${2:-}"
server_name="${3:-}"
tool_name="${4:-}"
max_repair_rounds="${5:-2}"
run_tests="${6:-true}"
run_code_review="${7:-true}"
run_security_review="${8:-true}"

if [[ -z "${artifact_type}" || -z "${requirements}" ]]; then
  echo "usage: runprompt_generate_artifact.sh <artifact_type> <requirements>" >&2
  exit 2
fi

case "${artifact_type}" in
  shell-as-mcp-bundle)
    ;;
  *)
    echo "artifact_type must be one of: shell-as-mcp-bundle" >&2
    exit 2
    ;;
esac

if [[ -z "${SHELL_AS_MCP_SPEC_DIR:-}" ]]; then
  echo "SHELL_AS_MCP_SPEC_DIR is not configured. Please set SHELL_AS_MCP_SPEC_DIR to an existing spec directory." >&2
  exit 2
fi

normalize_runprompt_env() {
  if [[ -n "${RUNPROMPT_MODEL:-}" && -z "${MODEL:-}" ]]; then
    export MODEL="${RUNPROMPT_MODEL}"
  fi

  if [[ -n "${RUNPROMPT_BASE_URL:-}" ]]; then
    if [[ -z "${BASE_URL:-}" ]]; then
      export BASE_URL="${RUNPROMPT_BASE_URL}"
    fi
    if [[ -z "${OPENAI_BASE_URL:-}" ]]; then
      export OPENAI_BASE_URL="${RUNPROMPT_BASE_URL}"
    fi
    if [[ -z "${OPENAI_API_BASE:-}" ]]; then
      export OPENAI_API_BASE="${RUNPROMPT_BASE_URL}"
    fi
  fi

  if [[ -n "${RUNPROMPT_OPENROUTER_API_KEY:-}" ]]; then
    if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
      export OPENROUTER_API_KEY="${RUNPROMPT_OPENROUTER_API_KEY}"
    fi
    if [[ -z "${API_KEY:-}" ]]; then
      export API_KEY="${RUNPROMPT_OPENROUTER_API_KEY}"
    fi
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
      export OPENAI_API_KEY="${RUNPROMPT_OPENROUTER_API_KEY}"
    fi
  fi
}

normalize_runprompt_env

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${SHELL_AS_MCP_RUNPROMPT_DIAGNOSTIC:-false}" =~ ^(1|true|yes|on)$ ]]; then
  echo "[runprompt-diagnostic] bootstrap tool_path=${script_dir} provider_model=${MODEL:-${RUNPROMPT_MODEL:-}} base_url=${RUNPROMPT_BASE_URL:-${BASE_URL:-${OPENAI_BASE_URL:-}}}" >&2
fi

python3 "${script_dir}/runprompt_generate_artifact.py" \
  "${artifact_type}" \
  "${requirements}" \
  "${server_name}" \
  "${tool_name}" \
  "${max_repair_rounds}" \
  "${run_tests}" \
  "${run_code_review}" \
  "${run_security_review}"
