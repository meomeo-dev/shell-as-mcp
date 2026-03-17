"""
runprompt_tools.py — Safe file-system tools for runprompt LLM sessions.

Exposed to the LLM via --tool-path <scripts_dir> --safe-yes.
Functions with docstrings become callable tools. The `safe: true` marker in
the docstring tells runprompt to auto-approve without user confirmation.
"""

import base64
import fnmatch
import json
import mimetypes
import os
import subprocess
from pathlib import Path


def read_file(path: str) -> str:
    """Read the complete text content of a file at the given path.

    Use this when you need to inspect file contents that were not pre-loaded
    in the prompt context, or when you want to verify the current on-disk
    state of a previously generated file.

    safe: true
    """
    try:
        p = _resolve_path(path)
    except ValueError as e:
        return f"[read_file error] {e}"
    ok, bridge_text = _run_bridge(op="read", path=p)
    if ok:
        return bridge_text
    if not p.exists():
        return f"[read_file error] File not found: {path}"
    if not p.is_file():
        return f"[read_file error] Path is not a file: {path}"
    # Limit size to prevent overwhelming the context window.
    max_bytes = 64 * 1024  # 64 KiB
    try:
        text = p.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        return f"[read_file error] Could not read {path}: {e}"
    if len(text) > max_bytes:
        text = (
            text[:max_bytes]
            + f"\n... [truncated, file has {p.stat().st_size} bytes total]"
        )
    return text


def read_text_file(path: str) -> str:
    """Read the complete text content of a file.

    safe: true
    """
    return read_file(path)


def read_media_file(path: str) -> str:
    """Read a binary file and return a compact JSON payload.

    Returns: {"path", "mimeType", "data"} where data is base64 encoded.

    safe: true
    """
    try:
        p = _resolve_path(path)
    except ValueError as e:
        return f"[read_media_file error] {e}"
    if not p.exists() or not p.is_file():
        return f"[read_media_file error] Path is not a file: {path}"
    try:
        raw = p.read_bytes()
    except OSError as e:
        return f"[read_media_file error] Could not read {path}: {e}"
    mime_type, _ = mimetypes.guess_type(str(p))
    payload = {
        "path": str(p),
        "mimeType": mime_type or "application/octet-stream",
        "data": base64.b64encode(raw).decode("ascii"),
    }
    return json.dumps(payload, ensure_ascii=False)


def read_multiple_files(paths: str) -> str:
    """Read multiple files separated by newline or comma.

    safe: true
    """
    raw_items = [item.strip() for item in paths.replace(",", "\n").splitlines()]
    items = [item for item in raw_items if item]
    if not items:
        return "[read_multiple_files error] no paths provided"
    chunks: list[str] = []
    for item in items:
        chunks.append(f"{item}:\n{read_file(item)}")
    return "\n---\n".join(chunks)


def list_directory(path: str) -> str:
    """List the files and sub-directories in a directory.

    Returns one entry per line in the format '<type> <name>' where type is
    either 'file' or 'dir'. Hidden entries (starting with '.') are included.

    safe: true
    """
    try:
        p = _resolve_path(path)
    except ValueError as e:
        return f"[list_directory error] {e}"
    if not p.exists():
        return f"[list_directory error] Path not found: {path}"
    if not p.is_dir():
        return f"[list_directory error] Path is not a directory: {path}"
    try:
        entries = sorted(p.iterdir(), key=lambda e: (not e.is_dir(), e.name))
    except OSError as e:
        return f"[list_directory error] Could not list {path}: {e}"
    lines = []
    for entry in entries:
        kind = "dir " if entry.is_dir() else "file"
        lines.append(f"{kind} {entry.name}")
    if not lines:
        return "(empty directory)"
    return "\n".join(lines)


def list_directory_with_sizes(path: str, sort_by: str = "name") -> str:
    """List directory entries with byte sizes.

    `sort_by` supports `name` or `size`.

    safe: true
    """
    try:
        p = _resolve_path(path)
    except ValueError as e:
        return f"[list_directory_with_sizes error] {e}"
    if not p.exists() or not p.is_dir():
        return f"[list_directory_with_sizes error] Path is not a directory: {path}"
    try:
        entries = list(p.iterdir())
    except OSError as e:
        return f"[list_directory_with_sizes error] Could not list {path}: {e}"

    with_sizes: list[tuple[Path, int]] = []
    for entry in entries:
        size = 0
        if entry.is_file():
            try:
                size = entry.stat().st_size
            except OSError:
                size = 0
        with_sizes.append((entry, size))

    if sort_by == "size":
        with_sizes.sort(key=lambda item: (item[1], item[0].name.lower()))
    else:
        with_sizes.sort(key=lambda item: item[0].name.lower())

    lines: list[str] = []
    for entry, size in with_sizes:
        if entry.is_dir():
            lines.append(f"[DIR]  {entry.name}")
        else:
            lines.append(f"[FILE] {entry.name} ({size} bytes)")
    return "\n".join(lines) if lines else "(empty directory)"


def directory_tree(path: str, exclude_patterns: str = "") -> str:
    """Return a JSON directory tree.

    `exclude_patterns` accepts comma-separated glob patterns.

    safe: true
    """
    patterns = [p.strip() for p in exclude_patterns.split(",") if p.strip()]
    try:
        root = _resolve_path(path)
    except ValueError as e:
        return f"[directory_tree error] {e}"
    if not root.exists() or not root.is_dir():
        return f"[directory_tree error] Path is not a directory: {path}"

    def is_excluded(rel_path: str) -> bool:
        return any(fnmatch.fnmatch(rel_path, pat) for pat in patterns)

    def walk(node: Path, rel: str) -> dict[str, object]:
        item: dict[str, object] = {
            "name": node.name if rel else node.name or ".",
            "type": "directory" if node.is_dir() else "file",
        }
        if node.is_dir():
            children: list[dict[str, object]] = []
            for child in sorted(node.iterdir(), key=lambda e: e.name.lower()):
                child_rel = f"{rel}/{child.name}" if rel else child.name
                if is_excluded(child_rel):
                    continue
                children.append(walk(child, child_rel))
            item["children"] = children
        return item

    return json.dumps(walk(root, ""), ensure_ascii=False, indent=2)


def search_files(path: str, pattern: str, exclude_patterns: str = "") -> str:
    """Search recursively for files matching a glob pattern.

    `exclude_patterns` accepts comma-separated glob patterns.

    safe: true
    """
    try:
        root = _resolve_path(path)
    except ValueError as e:
        return f"[search_files error] {e}"
    if not root.exists() or not root.is_dir():
        return f"[search_files error] Path is not a directory: {path}"

    excludes = [p.strip() for p in exclude_patterns.split(",") if p.strip()]
    matches: list[str] = []
    for candidate in root.rglob("*"):
        rel = str(candidate.relative_to(root))
        if excludes and any(fnmatch.fnmatch(rel, ex) for ex in excludes):
            continue
        if fnmatch.fnmatch(candidate.name, pattern) or fnmatch.fnmatch(rel, pattern):
            matches.append(str(candidate))
    return "\n".join(sorted(matches)) if matches else "(no matches)"


def get_file_info(path: str) -> str:
    """Return file or directory metadata as JSON.

    safe: true
    """
    try:
        p = _resolve_path(path)
    except ValueError as e:
        return f"[get_file_info error] {e}"
    if not p.exists():
        return f"[get_file_info error] Path not found: {path}"
    try:
        st = p.stat()
    except OSError as e:
        return f"[get_file_info error] Could not stat {path}: {e}"
    payload = {
        "path": str(p),
        "name": p.name,
        "type": "directory" if p.is_dir() else "file",
        "size": st.st_size,
        "created": st.st_ctime,
        "modified": st.st_mtime,
        "accessed": st.st_atime,
        "mode": st.st_mode,
    }
    return json.dumps(payload, ensure_ascii=False)


def list_allowed_directories() -> str:
    """Return allowed root directories for tool operations.

    safe: true
    """
    roots = [str(_tool_root())]
    raw = os.environ.get("SHELL_AS_MCP_EXTRA_ALLOWED_DIRS", "").strip()
    if raw:
        for item in raw.split(","):
            part = item.strip()
            if part:
                roots.append(str(Path(part).expanduser().resolve()))
    return "\n".join(dict.fromkeys(roots))


def move_file(source: str, destination: str) -> str:
    """Move or rename a file or directory.

    safe: true
    """
    try:
        src = _resolve_path(source)
        dst = _resolve_path(destination)
    except ValueError as e:
        return f"[move_file error] {e}"
    if not src.exists():
        return f"[move_file error] Source not found: {source}"
    if dst.exists():
        return f"[move_file error] Destination already exists: {destination}"
    try:
        dst.parent.mkdir(parents=True, exist_ok=True)
        src.rename(dst)
    except OSError as e:
        return f"[move_file error] Could not move {source}: {e}"
    return f"[move_file ok] {src} -> {dst}"


def write_file(path: str, content: str) -> str:
    """Write text content to a file, creating parent directories if needed.

    safe: true
    """
    try:
        p = _resolve_path(path)
    except ValueError as e:
        return f"[write_file error] {e}"
    ok, bridge_text = _run_bridge(op="write", path=p, content=content)
    if ok:
        return bridge_text or f"[write_file ok] {p}"

    if not _fallback_local_enabled():
        return f"[write_file error] bridge write failed for: {path}"

    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
    except OSError as e:
        return f"[write_file error] Could not write {path}: {e}"
    return f"[write_file ok] {p}"


def create_directory(path: str) -> str:
    """Create a directory recursively.

    safe: true
    """
    try:
        p = _resolve_path(path)
    except ValueError as e:
        return f"[create_directory error] {e}"
    ok, bridge_text = _run_bridge(op="mkdir", path=p)
    if ok:
        return bridge_text or f"[create_directory ok] {p}"

    if not _fallback_local_enabled():
        return f"[create_directory error] bridge mkdir failed for: {path}"

    try:
        p.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        return f"[create_directory error] Could not create {path}: {e}"
    return f"[create_directory ok] {p}"


def edit_file(
    path: str,
    old_text: str,
    new_text: str,
    replace_all: bool = False,
) -> str:
    """Replace old text with new text in a file.

    If replace_all is false, only the first match is replaced.

    safe: true
    """
    try:
        p = _resolve_path(path)
    except ValueError as e:
        return f"[edit_file error] {e}"
    if not replace_all:
        ok, bridge_text = _run_bridge(
            op="edit",
            path=p,
            old_text=old_text,
            new_text=new_text,
        )
        if ok:
            return bridge_text or f"[edit_file ok] {p}"

    if not _fallback_local_enabled():
        return f"[edit_file error] bridge edit failed for: {path}"

    try:
        source = p.read_text(encoding="utf-8")
    except OSError as e:
        return f"[edit_file error] Could not read {path}: {e}"

    if old_text not in source:
        return f"[edit_file error] old_text not found in: {path}"

    if replace_all:
        updated = source.replace(old_text, new_text)
    else:
        updated = source.replace(old_text, new_text, 1)

    try:
        p.write_text(updated, encoding="utf-8")
    except OSError as e:
        return f"[edit_file error] Could not write {path}: {e}"
    return f"[edit_file ok] {p}"


def _delete_file(path: str) -> str:
    """Internal file deletion helper used for compatibility fallback paths."""
    try:
        p = _resolve_path(path)
    except ValueError as e:
        return f"[delete_file error] {e}"
    ok, bridge_text = _run_bridge(op="delete", path=p)
    if ok:
        return bridge_text or f"[delete_file ok] {p}"

    if not _fallback_local_enabled():
        return f"[delete_file error] bridge delete failed for: {path}"

    if not p.exists():
        return f"[delete_file ok] already absent: {p}"
    try:
        p.unlink()
    except OSError as e:
        return f"[delete_file error] Could not delete {path}: {e}"
    return f"[delete_file ok] {p}"


def _tool_root() -> Path:
    configured = os.environ.get("SHELL_AS_MCP_RUNPROMPT_TOOL_ROOT", "").strip()
    if configured:
        return Path(configured).expanduser().resolve()

    spec_dir = os.environ.get("SHELL_AS_MCP_SPEC_DIR", "").strip()
    if spec_dir:
        return Path(spec_dir).expanduser().resolve()

    return Path.cwd().resolve()


def _resolve_path(path: str) -> Path:
    root = _tool_root()
    candidate = Path(path).expanduser()
    if candidate.is_absolute():
        resolved = candidate.resolve()
    else:
        resolved = (root / candidate).resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        raise ValueError(f"Path outside allowed root: {path}")
    return resolved


def _bridge_enabled() -> bool:
    return os.environ.get("SHELL_AS_MCP_FILESYSTEM_MCP_ENABLE", "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def _fallback_local_enabled() -> bool:
    value = os.environ.get("SHELL_AS_MCP_FILESYSTEM_FALLBACK_LOCAL", "true")
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _run_bridge(
    *,
    op: str,
    path: Path,
    content: str | None = None,
    old_text: str | None = None,
    new_text: str | None = None,
) -> tuple[bool, str]:
    if not _bridge_enabled():
        return False, ""

    script = Path(__file__).resolve().parent / "mcp_filesystem_bridge.mjs"
    command = [
        "node",
        str(script),
        "--root",
        str(_tool_root()),
        "--op",
        op,
        "--path",
        str(path),
    ]

    if content is not None:
        encoded = base64.b64encode(content.encode("utf-8")).decode("ascii")
        command.extend(["--content-base64", encoded])

    if old_text is not None and new_text is not None:
        old_encoded = base64.b64encode(old_text.encode("utf-8")).decode("ascii")
        new_encoded = base64.b64encode(new_text.encode("utf-8")).decode("ascii")
        command.extend(["--old-text-base64", old_encoded])
        command.extend(["--new-text-base64", new_encoded])

    proc = subprocess.run(
        command,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return False, proc.stderr.strip()
    return True, proc.stdout
