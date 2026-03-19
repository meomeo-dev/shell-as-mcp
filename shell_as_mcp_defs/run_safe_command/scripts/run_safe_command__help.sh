#!/usr/bin/env bash
set -euo pipefail

topic="${TOOL_TOPIC:-all}"

python3 - "$topic" <<'PYEOF'
import json
import sys

topic = (sys.argv[1] or "all").strip().lower()

help_payload = {
    "bundle": "run_safe_command",
    "topics": {
        "execute": {
            "tool": "run_safe_command__execute",
            "required": ["command", "args_json", "working_dir"],
            "optional": [],
            "notes": [
                "args_json must be a JSON array of strings",
                "command is executed directly without shell eval",
                "TOOL_EXECUTE_OUTPUT_MODE defaults to concise and supports full",
                "concise returns request/execution/authorization(core)/audit(minimal)",
                "on darwin/arm64 authorization prefers native Swift+WKWebView and auto-fallbacks to OSA",
                "OSA prompt fields align with widget order: Command, Args, Working Dir, Context Digest",
                "set TOOL_DEFAULT_APPROVALS=1 or DEFAULT_APPROVALS=true to use risky-command-only authorization",
                "trace, explanation, and audit rotation policies are internal-only",
            ],
        },
        "audit": {
            "tool": "run_safe_command__audit_get",
            "notes": [
                "returns latest records from ndjson audit log",
                "default limit is 20 entries",
                "can include rotated files for historical inspection"
            ],
        },
        "audit_rotate": {
            "tool": "run_safe_command__audit_rotate",
            "notes": [
                "rotates active audit file immediately",
                "enforces retention of rotated files"
            ]
        },
        "healthz": {
            "tool": "run_safe_command__healthz",
            "notes": [
                "checks required runtime dependencies",
                "optional trace backend absence is warning-only",
                "reports darwin dtruss privilege readiness",
                "reports explainshell provider readiness"
            ],
        },
        "widget": {
            "path": "shell_as_mcp_defs/run_safe_command/widget/index.html",
            "host_bridge_demo": "shell_as_mcp_defs/run_safe_command/widget/host_bridge_demo.html",
            "notes": [
                "frontend authorization modal plugin",
                "host demo injects runSafeCommandExecute and calls runSafeCommandAuthWidget.setRequest",
                "supports countdown, keyboard focus, and approve/deny actions"
            ]
        },
        "security": {
            "guardrails": [
                "no-shell-eval",
                "json-arg-validation",
                "absolute-working-dir-validation",
                "risky-command-confirmation-gate",
                "pre-execution-authorization-prompt",
            ]
        },
    },
}

if topic in {"all", ""}:
    output = help_payload
elif topic in help_payload["topics"]:
    output = {
        "bundle": "run_safe_command",
        "topic": topic,
        "content": help_payload["topics"][topic],
    }
else:
    output = {
        "bundle": "run_safe_command",
        "topic": topic,
        "error": "unknown topic",
        "supported_topics": sorted(help_payload["topics"].keys()),
    }

print(json.dumps(output, ensure_ascii=True))
PYEOF
