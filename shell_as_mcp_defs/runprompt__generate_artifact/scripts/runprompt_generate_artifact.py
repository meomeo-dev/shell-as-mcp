#!/usr/bin/env python3
"""runprompt orchestrator with a lightweight agent loop."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import importlib.util
import inspect
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Literal, TypedDict

VALID_ARTIFACT_TYPES = {
    "shell-as-mcp-bundle",
}

# ---------------------------------------------------------------------------
# GENERATE_FILES 操作类型定义（Operation Types for GENERATE_FILES stage）
# ---------------------------------------------------------------------------

# 文件生成操作类型：create = 全量覆写；edit = 定向 hunk 补丁
GenerateOperation = Literal["create", "edit"]


class FileEditHunk(TypedDict):
    """单个 edit hunk：精确文本替换对（exact text substitution pair）。"""

    old_text: str  # 必须与文件中的原始文本完全逐字匹配（exact verbatim match）
    new_text: str  # 替换后的新文本（replacement text）


_DIAG_TOOL_CACHE: dict[str, list[str]] = {}


class EditFailedError(RuntimeError):
    """edit hunk 应用失败：old_text 在文件中找不到精确匹配。"""


class ParseEditHunksError(ValueError):
    """edit hunk 文本格式解析失败。"""


def now_ts() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def is_truthy(value: str) -> bool:
    normalized = value.strip().lower()
    return normalized in {"1", "true", "yes", "on"}


def normalize_runprompt_prompt_output(content: str) -> str:
    text = re.sub(r"(?m)^```[^\n]*\n?", "", content)
    lines = text.splitlines()
    start = None
    end = None
    for index, line in enumerate(lines):
        if line.strip() != "---":
            continue
        if start is None:
            start = index
            continue
        end = index
        break
    if start is not None and end is not None:
        return "\n".join(lines[start:]).strip("\n")
    return text.strip("\n")


def validate_runprompt_prompt_output(content: str) -> None:
    if not content.strip():
        raise ValueError("runprompt output is empty for runprompt-prompt")
    if "```" in content:
        raise ValueError("runprompt-prompt output must not contain markdown fences")
    if not content.startswith("---"):
        raise ValueError(
            "runprompt-prompt output must start with YAML frontmatter (---)"
        )

    lines = content.splitlines()
    second = None
    for index, line in enumerate(lines[1:], start=2):
        if line == "---":
            second = index
            break

    if second is None:
        raise ValueError(
            "runprompt-prompt output must contain closing YAML frontmatter"
        )

    frontmatter = "\n".join(lines[1 : second - 1])
    if not re.search(r"(?m)^model:\s*\S+", frontmatter):
        raise ValueError("runprompt-prompt frontmatter must include model")

    body = "\n".join(lines[second:]).strip()
    if not body:
        raise ValueError("runprompt-prompt output must include template body")


def resolve_type_spec_path(base_dir: Path, artifact_type: str) -> Path:
    mapping = {
        "script": "script.spec.md",
        "shell-as-mcp-yaml": "shell-as-mcp-yaml.spec.md",
        "runprompt-prompt": "runprompt-prompt.spec.md",
    }
    filename = mapping.get(artifact_type, "script.spec.md")
    return base_dir / "prompts" / "type-specs" / filename


def local_run_command(
    command: list[str],
    cwd: Path | None = None,
    timeout_sec: float | None = None,
) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout_sec,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout if isinstance(error.stdout, str) else ""
        stderr = error.stderr if isinstance(error.stderr, str) else ""
        timeout_msg = (
            "command timed out"
            f" after {timeout_sec:.1f}s"
            f"; command={command}"
        )
        merged_stderr = "\n".join(
            line for line in [timeout_msg, stderr.strip()] if line
        )
        return 124, stdout, merged_stderr


def bool_env(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return is_truthy(value)


def list_env(name: str, default: list[str] | None = None) -> list[str]:
    value = os.environ.get(name, "")
    if not value.strip():
        return default or []
    return [item.strip() for item in value.split(",") if item.strip()]


def float_env(name: str, default: float) -> float:
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    try:
        parsed = float(value)
    except ValueError:
        return default
    return parsed if parsed > 0 else default


def runprompt_timeout_sec() -> float:
    return float_env("SHELL_AS_MCP_RUNPROMPT_TIMEOUT_SEC", 120.0)


def diagnostic_enabled() -> bool:
    return bool_env(
        "SHELL_AS_MCP_RUNPROMPT_DIAGNOSTIC",
        bool_env("RUNPROMPT_DEBUG_PROMPT", False),
    )


def diagnostic_log(event: str, payload: dict[str, Any]) -> None:
    if not diagnostic_enabled():
        return
    line = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    print(f"[runprompt-diagnostic] {event} {line}", file=sys.stderr)


def prompt_model_from_frontmatter(prompt_file: Path) -> str:
    try:
        text = prompt_file.read_text(encoding="utf-8")
    except OSError:
        return ""
    match = re.search(r"(?m)^model:\s*(\S+)\s*$", text)
    return match.group(1) if match else ""


def split_provider(model_name: str) -> str:
    if not model_name:
        return ""
    if "/" in model_name:
        return model_name.split("/", 1)[0]
    return ""


def emit_runprompt_runtime_diagnostics(
    *,
    gate: str,
    prompt_file: Path,
    command: list[str],
    tool_path: Path | None,
) -> None:
    if not diagnostic_enabled():
        return
    prompt_model = prompt_model_from_frontmatter(prompt_file)
    env_model = os.environ.get("MODEL", "") or os.environ.get("RUNPROMPT_MODEL", "")
    effective_model = prompt_model or env_model
    provider = split_provider(effective_model)
    injected_tools = discover_runprompt_tools(tool_path)
    fs_tools = discover_filesystem_server_tools()
    diagnostic_log(
        "invoke",
        {
            "gate": gate,
            "dotprompt": str(prompt_file),
            "tool_path": str(tool_path) if tool_path else "",
            "provider": provider,
            "model": effective_model,
            "prompt_model": prompt_model,
            "env_model": env_model,
            "runprompt_injected_tools": injected_tools,
            "runprompt_injected_tool_count": len(injected_tools),
            "filesystem_server_tools": fs_tools,
            "filesystem_server_tool_count": len(fs_tools),
            "openai_base_url": os.environ.get("OPENAI_BASE_URL", ""),
            "base_url": os.environ.get("BASE_URL", ""),
            "runprompt_base_url": os.environ.get("RUNPROMPT_BASE_URL", ""),
            "command": command,
        },
    )


def discover_runprompt_tools(tool_path: Path | None) -> list[str]:
    if tool_path is None:
        return []
    cache_key = f"runprompt:{tool_path}"
    if cache_key in _DIAG_TOOL_CACHE:
        return _DIAG_TOOL_CACHE[cache_key]

    module_file = tool_path / "runprompt_tools.py"
    if not module_file.exists():
        _DIAG_TOOL_CACHE[cache_key] = []
        return []

    try:
        spec = importlib.util.spec_from_file_location(
            "runprompt_tools_diag",
            module_file,
        )
        if spec is None or spec.loader is None:
            _DIAG_TOOL_CACHE[cache_key] = []
            return []
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception:
        _DIAG_TOOL_CACHE[cache_key] = []
        return []

    names: list[str] = []
    for name in dir(module):
        if name.startswith("_"):
            continue
        obj = getattr(module, name)
        if not inspect.isfunction(obj):
            continue
        if obj.__module__ != module.__name__:
            continue
        if not inspect.getdoc(obj):
            continue
        names.append(name)

    names.sort()
    _DIAG_TOOL_CACHE[cache_key] = names
    return names


def discover_filesystem_server_tools() -> list[str]:
    cache_key = "filesystem-server"
    if cache_key in _DIAG_TOOL_CACHE:
        return _DIAG_TOOL_CACHE[cache_key]

    spec_dir = os.environ.get("SHELL_AS_MCP_SPEC_DIR", "").strip()
    if not spec_dir:
        _DIAG_TOOL_CACHE[cache_key] = []
        return []

    command = [
        "node",
        str(script_path("mcp_filesystem_bridge.mjs")),
        "--root",
        str(Path(spec_dir).resolve()),
        "--op",
        "list-tools",
    ]
    code, stdout, _stderr = local_run_command(command)
    if code != 0:
        _DIAG_TOOL_CACHE[cache_key] = []
        return []

    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        _DIAG_TOOL_CACHE[cache_key] = []
        return []

    tools = payload.get("tools", [])
    if not isinstance(tools, list):
        _DIAG_TOOL_CACHE[cache_key] = []
        return []

    normalized = sorted(str(item) for item in tools)
    _DIAG_TOOL_CACHE[cache_key] = normalized
    return normalized


def script_path(name: str) -> Path:
    return Path(__file__).resolve().parent / name


def filesystem_root(spec_dir: Path) -> Path:
    configured = os.environ.get("SHELL_AS_MCP_FILESYSTEM_ROOT", "").strip()
    if configured:
        return Path(configured).resolve()
    return spec_dir.resolve()


def run_sandboxed_command(
    command: list[str],
    cwd: Path | None = None,
    timeout_sec: float | None = None,
) -> tuple[int, str, str]:
    wrapper = [
        "node",
        str(script_path("sandbox_exec.mjs")),
        "--command-json",
        json.dumps(command, ensure_ascii=False),
    ]
    if cwd is not None:
        wrapper.extend(["--cwd", str(cwd)])
    return local_run_command(wrapper, timeout_sec=timeout_sec)


def run_command(
    command: list[str],
    cwd: Path | None = None,
    timeout_sec: float | None = None,
) -> tuple[int, str, str]:
    if not bool_env("SHELL_AS_MCP_SANDBOX_ENABLE", False):
        return local_run_command(command, cwd=cwd, timeout_sec=timeout_sec)

    code, stdout, stderr = run_sandboxed_command(
        command,
        cwd=cwd,
        timeout_sec=timeout_sec,
    )
    if code == 0:
        return code, stdout, stderr

    if bool_env("SHELL_AS_MCP_SANDBOX_FALLBACK_LOCAL", False):
        fallback_prefix = "[sandbox-fallback] "
        code, out2, err2 = local_run_command(
            command,
            cwd=cwd,
            timeout_sec=timeout_sec,
        )
        merged_stderr = f"{fallback_prefix}{stderr}\n{err2}".strip()
        return code, out2, merged_stderr

    return code, stdout, stderr


def call_filesystem_bridge(
    *,
    op: str,
    path: Path,
    spec_dir: Path,
    content: str | None = None,
    old_text: str | None = None,
    new_text: str | None = None,
) -> tuple[int, str, str]:
    command = [
        "node",
        str(script_path("mcp_filesystem_bridge.mjs")),
        "--root",
        str(filesystem_root(spec_dir)),
        "--op",
        op,
        "--path",
        str(path),
    ]
    if content is not None:
        encoded = base64.b64encode(content.encode("utf-8")).decode("ascii")
        command.extend(["--content-base64", encoded])
    if old_text is not None:
        command.extend([
            "--old-text-base64",
            base64.b64encode(old_text.encode("utf-8")).decode("ascii"),
        ])
    if new_text is not None:
        command.extend([
            "--new-text-base64",
            base64.b64encode(new_text.encode("utf-8")).decode("ascii"),
        ])
    return local_run_command(command)


def mkdir_p(path: Path, spec_dir: Path) -> None:
    if not bool_env("SHELL_AS_MCP_FILESYSTEM_MCP_ENABLE", False):
        path.mkdir(parents=True, exist_ok=True)
        return

    code, _stdout, stderr = call_filesystem_bridge(
        op="mkdir",
        path=path,
        spec_dir=spec_dir,
    )
    if code == 0:
        return

    if bool_env("SHELL_AS_MCP_FILESYSTEM_FALLBACK_LOCAL", True):
        path.mkdir(parents=True, exist_ok=True)
        return
    raise RuntimeError(stderr.strip() or "filesystem bridge mkdir failed")


def write_text(path: Path, content: str, spec_dir: Path) -> None:
    if not bool_env("SHELL_AS_MCP_FILESYSTEM_MCP_ENABLE", False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return

    code, _stdout, stderr = call_filesystem_bridge(
        op="write",
        path=path,
        spec_dir=spec_dir,
        content=content,
    )
    if code == 0:
        return

    if bool_env("SHELL_AS_MCP_FILESYSTEM_FALLBACK_LOCAL", True):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return
    raise RuntimeError(stderr.strip() or "filesystem bridge write failed")


def plan_bundle(
    prompt_file: Path,
    requirements: str,
    server_name: str,
    tool_name: str,
    debug_mode: bool,
    repair_task_def: dict[str, Any] | None = None,
    prev_round_files: dict[str, str] | None = None,
    tool_path: Path | None = None,
) -> dict[str, Any]:
    """Call LLM to produce a bundle_contract JSON for the 3-file bundle."""
    payload = json.dumps(
        {
            "requirements": requirements,
            "server_name": server_name,
            "tool_name": tool_name,
            "is_repair": bool(repair_task_def),
            "repair_task_def": repair_task_def or {},
            "prev_round_files": prev_round_files or {},
        },
        ensure_ascii=False,
    )
    command = _build_runprompt_base_command(prompt_file, debug_mode, tool_path)
    command.append(payload)
    emit_runprompt_runtime_diagnostics(
        gate="plan_bundle",
        prompt_file=prompt_file,
        command=command,
        tool_path=tool_path,
    )
    code, stdout, stderr = run_command(
        command,
        timeout_sec=runprompt_timeout_sec(),
    )
    if code != 0:
        raise RuntimeError(stderr.strip() or "plan_bundle runprompt call failed")
    # Strip potential markdown fences from LLM JSON output
    clean = re.sub(r"(?m)^```[^\n]*\n?", "", stdout).strip()
    try:
        return json.loads(clean)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"plan_bundle returned invalid JSON: {e}\nOutput was:\n{stdout[:500]}"
        ) from e


def format_already_generated(
    already_generated: dict[str, str],
) -> str:
    """Format already-generated files for the LLM context section."""
    if not already_generated:
        return ""
    type_to_fence = {
        "shell-as-mcp-yaml": "yaml",
        "script": "bash",
        "runprompt-prompt": "",
    }
    type_to_label = {
        "shell-as-mcp-yaml": "shell-as-mcp-yaml",
        "script": "script",
        "runprompt-prompt": "runprompt-prompt",
    }
    position_map = {
        "shell-as-mcp-yaml": "1/3",
        "script": "2/3",
        "runprompt-prompt": "3/3",
    }
    lines = ["## Already Generated Files This Round (stay consistent with these)"]
    for artifact_type, content in already_generated.items():
        label = type_to_label.get(artifact_type, artifact_type)
        pos = position_map.get(artifact_type, "?/3")
        fence = type_to_fence.get(artifact_type, "")
        lines.append(f"\n### [{pos}] {label}")
        lines.append(f"```{fence}")
        lines.append(content)
        lines.append("```")
    return "\n".join(lines)


def _build_runprompt_base_command(
    prompt_file: Path,
    debug_mode: bool,
    tool_path: Path | None = None,
) -> list[str]:
    """Build the base runprompt command list with optional tool-path injection."""
    command = ["runprompt"]
    if debug_mode:
        command.append("-v")
    if tool_path is not None and tool_path.is_dir():
        command.extend(["--tool-path", str(tool_path), "--safe-yes"])
    command.append(str(prompt_file))
    return command


def call_runprompt(
    prompt_file: Path,
    artifact_type: str,
    requirements: str,
    type_spec: str,
    debug_mode: bool,
    bundle_contract: str = "",
    already_generated: str = "",
    bundle_position: str = "",
    tool_path: Path | None = None,
    operation: GenerateOperation = "create",
) -> str:
    payload = json.dumps(
        {
            "artifact_type": artifact_type,
            "requirements": requirements,
            "type_spec": type_spec,
            "bundle_contract": bundle_contract,
            "already_generated": already_generated,
            "bundle_position": bundle_position,
            "operation": operation,
        },
        ensure_ascii=False,
    )
    command = _build_runprompt_base_command(prompt_file, debug_mode, tool_path)
    command.append(payload)
    emit_runprompt_runtime_diagnostics(
        gate=f"generate:{artifact_type}",
        prompt_file=prompt_file,
        command=command,
        tool_path=tool_path,
    )
    code, stdout, stderr = run_command(
        command,
        timeout_sec=runprompt_timeout_sec(),
    )
    if code != 0:
        raise RuntimeError(stderr.strip() or "runprompt failed")
    return stdout


def call_review_prompt(
    prompt_file: Path,
    files_context: dict[str, str],
    extra_context: dict[str, Any] | None,
    debug_mode: bool,
    tool_path: Path | None = None,
) -> dict[str, Any]:
    """调用 runprompt 执行 review gate，返回标准化 gate result dict。

    LLM 调用失败或返回非 JSON 时，返回 passed=False 而非 raise，
    确保 gate pipeline 不会因为 LLM 异常而崩溃。
    """
    payload = json.dumps(
        {
            "files": files_context,
            **(extra_context or {}),
        },
        ensure_ascii=False,
    )
    command = _build_runprompt_base_command(prompt_file, debug_mode, tool_path)
    command.append(payload)
    emit_runprompt_runtime_diagnostics(
        gate=f"review:{prompt_file.stem}",
        prompt_file=prompt_file,
        command=command,
        tool_path=tool_path,
    )
    code, stdout, stderr = run_command(
        command,
        timeout_sec=runprompt_timeout_sec(),
    )
    if code != 0:
        return {
            "passed": False,
            "stdout": "",
            "stderr": stderr.strip() or "LLM review call failed",
        }
    clean = re.sub(r"(?m)^```[^\n]*\n?", "", stdout).strip()
    try:
        result = json.loads(clean)
    except json.JSONDecodeError:
        return {
            "passed": False,
            "stdout": stdout[:300],
            "stderr": "review gate returned non-JSON response",
        }

    if not isinstance(result, dict):
        return {
            "passed": False,
            "stdout": stdout[:300],
            "stderr": "review gate returned JSON but top-level is not object",
        }

    required_keys = ("passed", "issues", "summary")
    missing = [key for key in required_keys if key not in result]
    if missing:
        missing_str = ", ".join(missing)
        return {
            "passed": False,
            "stdout": stdout[:300],
            "stderr": (
                "review gate returned invalid schema; "
                f"missing keys: {missing_str}"
            ),
        }

    if not isinstance(result.get("issues"), list):
        return {
            "passed": False,
            "stdout": stdout[:300],
            "stderr": "review gate returned invalid schema; issues must be a list",
        }

    if not isinstance(result.get("summary"), str):
        return {
            "passed": False,
            "stdout": stdout[:300],
            "stderr": "review gate returned invalid schema; summary must be a string",
        }
    issues = result.get("issues", [])
    # passed=False if any issue has severity == "error"
    has_error = any(
        i.get("severity", "error") == "error" for i in issues
    )
    passed = result.get("passed", not has_error)
    issue_lines = [
        (
            f"[{i.get('severity', 'error')}] "
            f"{i.get('file', '')}: {i.get('description', '')}"
        )
        for i in issues
        if i.get("severity", "error") in {"error", "warning"}
    ]
    return {
        "passed": passed,
        "stdout": result.get("summary", ""),
        "stderr": "\n".join(issue_lines),
    }


def write_audit_file(
    audit_dir: Path,
    name: str,
    payload: dict[str, Any],
    spec_dir: Path | None = None,
) -> Path:
    path = audit_dir / name
    root = spec_dir or audit_dir.parent.parent
    write_text(path, json.dumps(payload, ensure_ascii=False, indent=2), root)
    return path


def repo_root_from_script(script_dir: Path) -> Path:
    return script_dir.parent.parent.parent


def bundle_plan(
    spec_dir: Path,
    server_name: str,
    tool_name: str,
) -> list[dict[str, str]]:
    base = spec_dir / server_name
    return [
        {
            "artifact_type": "shell-as-mcp-yaml",
            "path": str(base / "spec_yaml" / f"{tool_name}.yaml"),
        },
        {
            "artifact_type": "script",
            "path": str(base / "scripts" / f"{tool_name}.sh"),
        },
        {
            "artifact_type": "runprompt-prompt",
            "path": str(base / "prompts" / f"{tool_name}.prompt"),
        },
    ]


def run_llm_code_review(
    generated_files: list[str],
    script_dir: Path,
    debug_mode: bool,
) -> dict[str, Any]:
    """LLM 语义代码质量评审：检查 shebang、set -euo pipefail、YAML 规范、dotprompt frontmatter 等。"""
    prompt_file = script_dir.parent / "prompts" / "code_review.prompt"
    # Use artifact-type keyed context instead of raw suffix
    typed_context: dict[str, str] = {}
    for f in generated_files:
        path = Path(f)
        if not path.exists():
            continue
        if path.suffix == ".yaml":
            typed_context["shell-as-mcp-yaml"] = path.read_text(encoding="utf-8")
        elif path.suffix == ".sh":
            typed_context["script"] = path.read_text(encoding="utf-8")
        elif path.suffix == ".prompt":
            typed_context["runprompt-prompt"] = path.read_text(encoding="utf-8")
    return call_review_prompt(
        prompt_file,
        typed_context,
        None,
        debug_mode,
        tool_path=script_dir,
    )


def run_llm_cross_file_consistency(
    generated_files: list[str],
    script_dir: Path,
    debug_mode: bool,
) -> dict[str, Any]:
    """LLM 跨文件参数契约一致性检查：YAML.fromParams ↔ Script env vars ↔ Prompt input.schema。"""
    prompt_file = script_dir.parent / "prompts" / "cross_file_consistency.prompt"
    typed_context: dict[str, str] = {}
    for f in generated_files:
        path = Path(f)
        if not path.exists():
            continue
        if path.suffix == ".yaml":
            typed_context["shell-as-mcp-yaml"] = path.read_text(encoding="utf-8")
        elif path.suffix == ".sh":
            typed_context["script"] = path.read_text(encoding="utf-8")
        elif path.suffix == ".prompt":
            typed_context["runprompt-prompt"] = path.read_text(encoding="utf-8")
    return call_review_prompt(
        prompt_file,
        typed_context,
        None,
        debug_mode,
        tool_path=script_dir,
    )


def run_security_review(generated_files: list[str]) -> dict[str, Any]:
    findings: list[str] = []
    checked: list[str] = []
    patterns: list[tuple[str, re.Pattern[str]]] = [
        ("eval", re.compile(r"(?m)\beval\b")),
        ("bash -c", re.compile(r"(?m)\bbash\s+-c\b")),
        ("sh -c", re.compile(r"(?m)\bsh\s+-c\b")),
        ("curl|sh", re.compile(r"(?m)curl[^\n]*\|\s*(?:sh|bash)\b")),
        ("wget|sh", re.compile(r"(?m)wget[^\n]*\|\s*(?:sh|bash)\b")),
        ("rm -rf /", re.compile(r"(?m)\brm\s+-rf(?:\s+--)?\s+/(?:\s|$)")),
        ("mkfs", re.compile(r"(?m)\bmkfs\b")),
        ("dd if=", re.compile(r"(?m)\bdd\s+if=")),
    ]

    for file_str in generated_files:
        path = Path(file_str)
        if not path.exists():
            continue
        if path.suffix not in {".sh", ".prompt", ".yaml", ".yml"}:
            continue
        checked.append(str(path))
        content = path.read_text(encoding="utf-8")
        for name, pattern in patterns:
            if pattern.search(content):
                findings.append(f"{path}: contains high-risk pattern '{name}'")

    return {
        "passed": not findings,
        "stdout": "checked files: " + ", ".join(checked),
        "stderr": "\n".join(findings),
    }


def run_llm_security_review(
    generated_files: list[str],
    script_dir: Path,
    debug_mode: bool,
) -> dict[str, Any]:
    """LLM OWASP Top 10 语义安全分析：命令注入、SSRF、权限提升、动态代码执行等。"""
    prompt_file = script_dir.parent / "prompts" / "security_review_llm.prompt"
    typed_context: dict[str, str] = {}
    for f in generated_files:
        path = Path(f)
        if not path.exists():
            continue
        if path.suffix == ".yaml":
            typed_context["shell-as-mcp-yaml"] = path.read_text(encoding="utf-8")
        elif path.suffix == ".sh":
            typed_context["script"] = path.read_text(encoding="utf-8")
        elif path.suffix == ".prompt":
            typed_context["runprompt-prompt"] = path.read_text(encoding="utf-8")
    return call_review_prompt(
        prompt_file,
        typed_context,
        None,
        debug_mode,
        tool_path=script_dir,
    )


def run_generated_files_lint(
    repo_root: Path,
    generated_files: list[str],
) -> dict[str, Any]:
    lint_dir = repo_root / "scripts" / "lint"
    validator_map = {
        ".yaml": lint_dir / "validate_shell_as_mcp_yaml.sh",
        ".yml": lint_dir / "validate_shell_as_mcp_yaml.sh",
        ".sh": lint_dir / "validate_script.sh",
        ".prompt": lint_dir / "validate_runprompt_prompt.sh",
    }
    checked: list[str] = []
    failures: list[str] = []

    for file_str in generated_files:
        path = Path(file_str)
        if not path.exists():
            continue
        if path.suffix == ".prompt" and path.name.startswith("_"):
            continue
        validator = validator_map.get(path.suffix)
        if validator is None:
            continue
        checked.append(str(path))
        code, stdout, stderr = run_command(
            ["bash", str(validator), str(path)],
            cwd=repo_root,
        )
        if code != 0:
            detail = stderr.strip() or stdout.strip() or "validation failed"
            failures.append(f"{path}: {detail}")

    if not checked:
        return {"passed": True, "stdout": "no lintable generated files", "stderr": ""}

    return {
        "passed": not failures,
        "stdout": "checked files: " + ", ".join(checked),
        "stderr": "\n".join(failures),
    }


def run_quality_gates(
    repo_root: Path,
    run_tests: bool,
    generated_files: list[str],
    run_code_review_enabled: bool,
    run_security_review_enabled: bool,
    script_dir: Path,
    debug_mode: bool,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "lint": run_generated_files_lint(repo_root, generated_files)
    }
    if run_tests:
        test_code, test_stdout, test_stderr = run_command(
            ["npm", "test", "--", "runprompt-generate-artifact.test.ts"],
            cwd=repo_root,
        )
        result["test"] = {
            "passed": test_code == 0,
            "stdout": test_stdout.strip(),
            "stderr": test_stderr.strip(),
        }
    else:
        result["test"] = {
            "passed": True,
            "stdout": "skipped",
            "stderr": "",
        }

    if run_code_review_enabled:
        result["code_review"] = run_llm_code_review(
            generated_files, script_dir, debug_mode
        )
    else:
        result["code_review"] = {
            "passed": True,
            "stdout": "skipped",
            "stderr": "",
        }

    if run_security_review_enabled:
        result["security_review"] = run_security_review(generated_files)
        result["security_review_llm"] = run_llm_security_review(
            generated_files, script_dir, debug_mode
        )
    else:
        result["security_review"] = {
            "passed": True,
            "stdout": "skipped",
            "stderr": "",
        }
        result["security_review_llm"] = {
            "passed": True,
            "stdout": "skipped",
            "stderr": "",
        }

    if run_code_review_enabled:
        result["cross_file_consistency"] = run_llm_cross_file_consistency(
            generated_files, script_dir, debug_mode
        )
    else:
        result["cross_file_consistency"] = {
            "passed": True,
            "stdout": "skipped",
            "stderr": "",
        }
    return result


def quality_passed(gates: dict[str, Any]) -> bool:
    for value in gates.values():
        if not value.get("passed"):
            return False
    return True


def llm_summarize_quality_failures(
    gates: dict[str, Any],
    generated_files: list[str],
    script_dir: Path,
    debug_mode: bool,
) -> dict[str, Any]:
    """LLM 根因分析并生成结构化 Repair Task Definition。

    Returns RepairTaskDef dict:
      {repair_strategy, files_to_fix, issues_by_file, root_cause}

    调用失败时返回 fallback dict（text-based summary），不 raise。
    """
    prompt_file = script_dir.parent / "prompts" / "summarize_failures.prompt"
    # Build files context (only existing files)
    typed_context: dict[str, str] = {}
    for f in generated_files:
        path = Path(f)
        if not path.exists():
            continue
        if path.suffix == ".yaml":
            typed_context["shell-as-mcp-yaml"] = path.read_text(encoding="utf-8")
        elif path.suffix == ".sh":
            typed_context["script"] = path.read_text(encoding="utf-8")
        elif path.suffix == ".prompt":
            typed_context["runprompt-prompt"] = path.read_text(encoding="utf-8")
    # Build gates failure summary text
    failure_lines: list[str] = []
    for key, value in gates.items():
        if value.get("passed"):
            continue
        stderr = value.get("stderr", "")
        snippet = stderr[:500].strip()
        if not snippet:
            snippet = str(value.get("stdout", ""))[:500].strip()
        failure_lines.append(f"{key}: {snippet}")
    gates_failures_str = "\n".join(failure_lines)

    payload = json.dumps(
        {
            "files": typed_context,
            "gates_failures": gates_failures_str,
        },
        ensure_ascii=False,
    )
    command = _build_runprompt_base_command(
        prompt_file,
        debug_mode,
        tool_path=script_dir,
    )
    command.append(payload)
    code, stdout, stderr_out = run_command(
        command,
        timeout_sec=runprompt_timeout_sec(),
    )

    if code != 0:
        # Fallback: text-based summary
        return {
            "repair_strategy": gates_failures_str[:500],
            "files_to_fix": ["shell-as-mcp-yaml", "script", "runprompt-prompt"],
            "issues_by_file": {
                "shell-as-mcp-yaml": [],
                "script": [],
                "runprompt-prompt": [],
            },
            "root_cause": gates_failures_str[:200],
        }

    clean = re.sub(r"(?m)^```[^\n]*\n?", "", stdout).strip()
    try:
        result = json.loads(clean)
        # Ensure all required keys exist
        result.setdefault("repair_strategy", gates_failures_str[:300])
        result.setdefault("files_to_fix", [])
        result.setdefault(
            "issues_by_file",
            {"shell-as-mcp-yaml": [], "script": [], "runprompt-prompt": []},
        )
        result.setdefault("root_cause", "")
        return result
    except json.JSONDecodeError:
        return {
            "repair_strategy": stdout[:300],
            "files_to_fix": ["shell-as-mcp-yaml", "script", "runprompt-prompt"],
            "issues_by_file": {
                "shell-as-mcp-yaml": [],
                "script": [],
                "runprompt-prompt": [],
            },
            "root_cause": "LLM summarize_failures returned non-JSON",
        }


def generate_bundle(args: argparse.Namespace, script_dir: Path) -> int:
    spec_dir = Path(args.spec_dir).resolve()
    prompt_file = script_dir.parent / "prompts" / "generate_artifact.prompt"
    edit_prompt_file = (
        script_dir.parent / "prompts" / "generate_artifact_edit.prompt"
    )
    repo_root = repo_root_from_script(script_dir)

    # Limit runprompt tool-path file operations to the configured spec root.
    os.environ.setdefault("SHELL_AS_MCP_RUNPROMPT_TOOL_ROOT", str(spec_dir))

    audit_dir = spec_dir / "generated-artifacts" / "audit"
    mkdir_p(audit_dir, spec_dir)
    audit_prefix = now_ts()

    server_name = args.server_name or "generated_server"
    tool_name = args.tool_name or f"{server_name}__generated_tool"
    plan = bundle_plan(spec_dir, server_name, tool_name)

    write_audit_file(
        audit_dir,
        f"{audit_prefix}_plan.json",
        {"state": "PLAN", "artifact_type": args.artifact_type, "files": plan},
        spec_dir,
    )

    # ── Planning Phase ────────────────────────────────────────────
    plan_prompt_file = script_dir.parent / "prompts" / "plan_bundle.prompt"
    bundle_contract_dict = plan_bundle(
        plan_prompt_file,
        args.requirements,
        server_name,
        tool_name,
        args.debug_prompt,
        tool_path=script_dir,
    )
    bundle_contract_str = json.dumps(
        bundle_contract_dict, ensure_ascii=False, indent=2
    )
    write_audit_file(
        audit_dir,
        f"{audit_prefix}_bundle_contract.json",
        {"state": "BUNDLE_CONTRACT", "contract": bundle_contract_dict},
        spec_dir,
    )
    # ──────────────────────────────────────────────────────────────

    failure_feedback = ""
    generated_files: list[str] = []
    quality: dict[str, Any] = {}

    repair_task_def: dict[str, Any] | None = None
    prev_round_files: dict[str, str] = {}

    for repair_round in range(args.max_repair_rounds + 1):
        if repair_round > 0:
            # Re-plan with repair context
            bundle_contract_dict = plan_bundle(
                plan_prompt_file,
                args.requirements,
                server_name,
                tool_name,
                args.debug_prompt,
                repair_task_def=repair_task_def,
                prev_round_files=prev_round_files,
                tool_path=script_dir,
            )
            bundle_contract_str = json.dumps(
                bundle_contract_dict, ensure_ascii=False, indent=2
            )
            write_audit_file(
                audit_dir,
                f"{audit_prefix}_round_{repair_round}_repair_bundle_contract.json",
                {
                    "state": "REPAIR_BUNDLE_CONTRACT",
                    "round": repair_round,
                    "contract": bundle_contract_dict,
                },
                spec_dir,
            )
        generated_files = []
        already_generated_files: dict[str, str] = {}
        state = {
            "state": "GENERATE_FILES",
            "round": repair_round,
            "files": [],
        }

        for item in plan:
            target = Path(item["path"])
            type_spec_path = resolve_type_spec_path(
                script_dir.parent,
                item["artifact_type"],
            )
            type_spec = type_spec_path.read_text(encoding="utf-8")
            requirements = args.requirements
            requirements += (
                f"\n\nTarget path: {target}."
                f"\nServer name: {server_name}."
                f"\nTool name: {tool_name}."
            )
            if failure_feedback:
                requirements += (
                    "\n\nQuality failure feedback (must fix):\n"
                    + failure_feedback
                )

            # repair round 时注入上轮该文件内容（帮助 LLM 理解之前的错误）
            per_file_reqs = requirements
            if repair_round > 0:
                prev_content = prev_round_files.get(item["artifact_type"], "")
                if prev_content:
                    per_file_reqs += (
                        f"\n\nPrevious attempt at this file "
                        f"(round {repair_round - 1}, needs fixing):\n"
                        + prev_content
                    )

            operation = decide_operation(
                repair_round,
                repair_task_def or {},
                item["artifact_type"],
                target,
            )
            current_prompt = (
                edit_prompt_file
                if operation == "edit" and edit_prompt_file.exists()
                else prompt_file
            )
            if current_prompt is edit_prompt_file and not edit_prompt_file.exists():
                # edit prompt 文件尚未创建时降级到 create
                operation = "create"
                current_prompt = prompt_file

            # 短路：edit 模式下，若该文件无任何 issue，直接保留现有内容，跳过 LLM 调用
            if operation == "edit" and target.exists() and repair_task_def:
                file_issues = (repair_task_def.get("issues_by_file") or {}).get(
                    item["artifact_type"], None
                )
                if file_issues is not None and len(file_issues) == 0:
                    actual_content = target.read_text(encoding="utf-8")
                    already_generated_files[item["artifact_type"]] = actual_content
                    generated_files.append(str(target))
                    state["files"].append(
                        {
                            "path": str(target),
                            "bytes": len(actual_content),
                            "operation": "edit",
                        }
                    )
                    continue  # 跳过本 artifact_type 的 LLM 调用

            raw_output = call_runprompt(
                prompt_file=current_prompt,
                artifact_type=item["artifact_type"],
                requirements=per_file_reqs,
                type_spec=type_spec,
                debug_mode=args.debug_prompt,
                bundle_contract=bundle_contract_str,
                already_generated=format_already_generated(
                    already_generated_files
                ),
                bundle_position=f"{plan.index(item) + 1}/{len(plan)}",
                tool_path=script_dir,
                operation=operation,
            )

            if operation == "create":
                content = raw_output
                if item["artifact_type"] == "runprompt-prompt":
                    content = normalize_runprompt_prompt_output(content)
                    validate_runprompt_prompt_output(content)
                write_text(target, content, spec_dir)
                actual_content = content

            else:  # operation == "edit"
                try:
                    hunks = parse_edit_hunks(raw_output)
                    if hunks:
                        apply_file_edits(target, hunks, spec_dir)
                    # 无 hunk（NO_CHANGES_NEEDED）或 apply 成功后读取实际内容
                    actual_content = (
                        target.read_text(encoding="utf-8")
                        if target.exists()
                        else raw_output
                    )
                except (EditFailedError, ParseEditHunksError) as exc:
                    # edit 失败 fallback：以 create 模式重新生成
                    print(
                        f"[warn] edit fallback to create for"
                        f" {item['artifact_type']}: {exc}",
                        file=sys.stderr,
                    )
                    fallback_output = call_runprompt(
                        prompt_file=prompt_file,
                        artifact_type=item["artifact_type"],
                        requirements=per_file_reqs,
                        type_spec=type_spec,
                        debug_mode=args.debug_prompt,
                        bundle_contract=bundle_contract_str,
                        already_generated=format_already_generated(
                            already_generated_files
                        ),
                        bundle_position=f"{plan.index(item) + 1}/{len(plan)}",
                        tool_path=script_dir,
                        operation="create",
                    )
                    content = fallback_output
                    if item["artifact_type"] == "runprompt-prompt":
                        content = normalize_runprompt_prompt_output(content)
                        validate_runprompt_prompt_output(content)
                    write_text(target, content, spec_dir)
                    actual_content = content
                    operation = "create"  # 审计记录为实际执行的操作

            already_generated_files[item["artifact_type"]] = actual_content
            generated_files.append(str(target))
            state["files"].append(
                {
                    "path": str(target),
                    "bytes": len(actual_content),
                    "operation": operation,
                }
            )

        write_audit_file(
            audit_dir,
            f"{audit_prefix}_round_{repair_round}_generate.json",
            state,
            spec_dir,
        )

        quality = run_quality_gates(
            repo_root,
            args.run_tests,
            generated_files,
            args.run_code_review,
            args.run_security_review,
            script_dir,
            args.debug_prompt,
        )
        write_audit_file(
            audit_dir,
            f"{audit_prefix}_round_{repair_round}_quality.json",
            {"state": "RUN_QUALITY_GATES", "round": repair_round, "quality": quality},
            spec_dir,
        )

        if quality_passed(quality):
            final_path = write_audit_file(
                audit_dir,
                f"{audit_prefix}_final.json",
                {
                    "state": "FINALIZE",
                    "server_name": server_name,
                    "tool_name": tool_name,
                    "generated_files": generated_files,
                    "quality": quality,
                },
                spec_dir,
            )
            print(f"generated_bundle:{spec_dir / server_name}")
            print(
                "generated_files:"
                + json.dumps(generated_files, ensure_ascii=False)
            )
            print("quality_gates:" + json.dumps(quality, ensure_ascii=False))
            print(f"audit_report:{final_path}")
            return 0

        # Step 1: LLM 生成结构化 Repair Task Definition
        repair_task_def = llm_summarize_quality_failures(
            quality, generated_files, script_dir, args.debug_prompt
        )
        write_audit_file(
            audit_dir,
            f"{audit_prefix}_round_{repair_round}_repair_task_def.json",
            {
                "state": "REPAIR_TASK_DEF",
                "round": repair_round,
                "repair_task_def": repair_task_def,
            },
            spec_dir,
        )
        # Use structured repair_task_def as text feedback for per-file injection.
        failure_feedback = json.dumps(repair_task_def, ensure_ascii=False, indent=2)
        prev_round_files = {
            item["artifact_type"]: Path(item["path"]).read_text(encoding="utf-8")
            for item in plan
            if Path(item["path"]).exists()
        }

    final_path = write_audit_file(
        audit_dir,
        f"{audit_prefix}_failed.json",
        {
            "state": "FAILED",
            "server_name": server_name,
            "tool_name": tool_name,
            "generated_files": generated_files,
            "quality": quality,
        },
        spec_dir,
    )
    # 先输出 per-gate 失败详情（便于测试断言和 CI 诊断）
    for key, val in quality.items():
        if not val.get("passed"):
            snippet = val.get("stderr", "")[:300].strip()
            if snippet:
                print(f"{key} failed: {snippet}", file=sys.stderr)
    # 再输出 repair_task_def（提供结构化根因分析）
    if repair_task_def:
        print(
            json.dumps(repair_task_def, ensure_ascii=False, indent=2),
            file=sys.stderr,
        )
    print("quality gates failed after repair loop", file=sys.stderr)
    print(f"audit_report:{final_path}")
    return 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact_type")
    parser.add_argument("requirements")
    parser.add_argument("server_name", nargs="?", default="")
    parser.add_argument("tool_name", nargs="?", default="")
    parser.add_argument("max_repair_rounds", nargs="?", default="2")
    parser.add_argument("run_tests", nargs="?", default="true")
    parser.add_argument("run_code_review", nargs="?", default="true")
    parser.add_argument("run_security_review", nargs="?", default="true")
    parser.add_argument("--spec-dir", default=os.environ.get("SHELL_AS_MCP_SPEC_DIR", ""))
    parser.add_argument(
        "--debug-prompt",
        action="store_true",
        default=is_truthy(os.environ.get("RUNPROMPT_DEBUG_PROMPT", "0")),
    )
    args = parser.parse_args()

    if args.artifact_type not in VALID_ARTIFACT_TYPES:
        parser.error(
            "artifact_type must be one of: "
            "shell-as-mcp-bundle"
        )

    if not args.spec_dir:
        parser.error("SHELL_AS_MCP_SPEC_DIR is not configured")

    try:
        args.max_repair_rounds = int(args.max_repair_rounds)
    except ValueError as error:
        raise ValueError("max_repair_rounds must be an integer") from error

    args.run_tests = is_truthy(str(args.run_tests))
    args.run_code_review = is_truthy(str(args.run_code_review))
    args.run_security_review = is_truthy(str(args.run_security_review))
    return args


# ---------------------------------------------------------------------------
# Edit 操作工具函数（Edit operation helpers）
# ---------------------------------------------------------------------------

_HUNK_HEADER_RE = re.compile(r"<<<EDIT_HUNK \d+/\d+>>>")
_SECTION_SPLIT_RE = re.compile(r"<<<(OLD|NEW|END_HUNK)>>>")


def parse_edit_hunks(text: str) -> list[FileEditHunk]:
    """解析 LLM 输出的 edit hunk 定界符格式，返回 FileEditHunk 列表。

    LLM 输出格式示例：
        <<<EDIT_HUNK 1/2>>>
        <<<OLD>>>
        old text verbatim
        <<<NEW>>>
        new replacement text
        <<<END_HUNK>>>

    特殊情况处理：
    - 输入为 "NO_CHANGES_NEEDED"（大小写不敏感）→ 返回 []
    - 无任何 <<<EDIT_HUNK 标记 → 返回 [] （调用方应 fallback to create）
    - 解析失败 → raise ParseEditHunksError
    """
    stripped = text.strip()
    if stripped.upper() == "NO_CHANGES_NEEDED":
        return []
    if not _HUNK_HEADER_RE.search(stripped):
        return []

    hunks: list[FileEditHunk] = []
    # 以 <<<EDIT_HUNK N/N>>> 为分隔符切分，第一段为空（header 前）
    blocks = _HUNK_HEADER_RE.split(stripped)
    for block in blocks:
        block = block.strip()
        if not block:
            continue
        # 去除 <<<END_HUNK>>> 及其后内容
        block = re.split(r"<<<END_HUNK>>>", block)[0].strip()
        if not block:
            continue
        # 以 <<<OLD>>> 和 <<<NEW>>> 分割
        parts = _SECTION_SPLIT_RE.split(block)
        # parts 形如: ["", "OLD", "\nold_text\n", "NEW", "\nnew_text\n"]
        # 或去掉空串后: ["OLD", "\nold_text\n", "NEW", "\nnew_text\n"]
        labeled: dict[str, str] = {}
        for index in range(len(parts)):
            if parts[index] in ("OLD", "NEW"):
                value = parts[index + 1] if index + 1 < len(parts) else ""
                # 去除首尾空行（保留中间缩进）
                labeled[parts[index]] = value.strip("\n")

        if "OLD" not in labeled or "NEW" not in labeled:
            raise ParseEditHunksError(
                f"edit hunk 缺少 <<<OLD>>> 或 <<<NEW>>> 标记: {block[:200]!r}"
            )
        hunks.append(
            FileEditHunk(old_text=labeled["OLD"], new_text=labeled["NEW"])
        )
    return hunks


def apply_file_edits(
    target: Path, hunks: list[FileEditHunk], spec_dir: Path
) -> None:
    """将 edit hunk 列表应用到目标文件。

    每个 hunk 依次顺序应用（sequential application）。
    优先通过 mcp_filesystem_bridge edit op 执行；
    若 SHELL_AS_MCP_FILESYSTEM_MCP_ENABLE=false（默认），则用 Python 字符串替换。

    raises EditFailedError: 若某 hunk 的 old_text 在文件中找不到精确匹配
    """
    for index, hunk in enumerate(hunks):
        if bool_env("SHELL_AS_MCP_FILESYSTEM_MCP_ENABLE", False):
            code, _stdout, stderr = call_filesystem_bridge(
                op="edit",
                path=target,
                spec_dir=spec_dir,
                old_text=hunk["old_text"],
                new_text=hunk["new_text"],
            )
            if code != 0:
                if bool_env("SHELL_AS_MCP_FILESYSTEM_FALLBACK_LOCAL", True):
                    _apply_hunk_local(target, hunk, index)
                else:
                    raise EditFailedError(
                        f"bridge edit hunk {index} failed: {stderr.strip()}"
                    )
        else:
            _apply_hunk_local(target, hunk, index)


def _apply_hunk_local(target: Path, hunk: FileEditHunk, index: int) -> None:
    """通过 Python 字符串替换应用单个 hunk 到文件（本地 fallback）。"""
    current = target.read_text(encoding="utf-8")
    if hunk["old_text"] not in current:
        raise EditFailedError(
            f"edit hunk {index}: old_text 在文件中找不到精确匹配。"
            f" 期望文本: {hunk['old_text'][:100]!r}"
        )
    updated = current.replace(hunk["old_text"], hunk["new_text"], 1)
    target.write_text(updated, encoding="utf-8")


def decide_operation(
    repair_round: int,
    repair_task_def: dict[str, Any],
    artifact_type: str,
    target: Path,
) -> GenerateOperation:
    """根据当前 repair_round 和 repair_task_def 决定文件生成操作类型。

    决策规则（Decision Rules）：
    1. repair_round == 0：文件尚不存在，始终 create
    2. target 文件不存在（异常情况）：fallback to create
    3. repair_task_def.operation_by_file 存在且有对应 artifact_type：使用其指定值
    4. 默认：edit（保守策略，宁可尝试 edit 失败后 fallback，也不盲目全量覆写）
    """
    if repair_round == 0:
        return "create"
    if not target.exists():
        return "create"
    operation_by_file: dict[str, str] = repair_task_def.get(
        "operation_by_file", {}
    )
    op = operation_by_file.get(artifact_type, "edit")
    # 防御性校验：只接受合法值，其余 fallback to edit
    if op not in ("create", "edit"):
        return "edit"
    return op  # type: ignore[return-value]


def main() -> int:
    args = parse_args()
    if not shutil_which("runprompt"):
        print("runprompt command not found in PATH", file=sys.stderr)
        return 127

    script_dir = Path(__file__).resolve().parent
    return generate_bundle(args, script_dir)


def shutil_which(command: str) -> str | None:
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(folder) / command
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
