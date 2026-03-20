<p align="center">
  <img src="icon.svg" width="120" alt="shell-as-mcp logo" />
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="https://github.com/meomeo-dev/shell-as-mcp"><img src="https://img.shields.io/github/stars/meomeo-dev/shell-as-mcp?style=social" alt="GitHub stars" /></a>
</p>

> 🌐 English | [中文](README.zh-CN.md)

# shell-as-mcp

<p align="center">
  <img src="image.png" alt="shell-as-mcp" width="500"/>
</p>

TypeScript Shell-as-MCP Server: maps shell commands to standard MCP tools via **single-file YAML specs**.

---

## 1) YAML Spec Design

Each YAML file defines one MCP tool. The root must contain `apiVersion`, `tool`, and `execution`.

```yaml
apiVersion: v1
tool:
  name: <server>__<action>        # snake_case, e.g. brew__install
  description: |-
    /**
     * One-line description of the tool's purpose (TSDoc format, sole description field).
     * @param param_name Parameter description
     */
  input:
    properties:
      param_name:
        type: string              # string | number | integer | boolean
        description: "..."
    required: [param_name]
  output:
    type: object
    properties:
      status:            { type: string }
      exit_code:         { type: number }
      stdout:            { type: string }
      stderr:            { type: string }
      command:           { type: string }
      execution_time_ms: { type: number }
execution:
  shell:
    mode: direct                  # direct | shell
    name: bash                    # optional: bash | zsh | sh | pwsh | cmd
    path: /usr/bin/bash           # optional, takes precedence over name
    args: ["-lc"]                 # optional, defaults used if omitted
  env:
    static:
      KEY: VALUE
    fromParams:
      TOOL_ENV_KEY: inputParamName  # UPPER_SNAKE_CASE; add TOOL_ prefix if unsure
    fromRuntime:
      TARGET_ENV: SOURCE_ENV        # maps from server runtime env; supports priority lists
      TOOL_OUTPUT_DIR: [YTDLP_OUTPUT_DIR, SHELL_AS_MCP_OUTPUT_DIR]
  compatibility:
    targets:
      - os: macos
        kernel: darwin
        arch: arm64
        support: tested            # optional: tested | declared
        notes: Apple Silicon only validated target
  workingDirectory: /tmp/work
  timeoutMs: 30000
  taskMode: sync                  # sync (default, returns result synchronously) | async (background task, returns taskId immediately)
  maxOutputBytes: 1048576
  # Script mode (recommended: always use this in bundles)
  script:
    path: ./scripts/<tool_name>.sh  # relative to the YAML file's directory
    interpreter: bash
  # Command mode (only for a single executable + static args; forbid && || ; | > < in args)
  # command:
  #   executable: ffmpeg
  #   args: ["-version"]
```

**Key constraints:**

- `tool.name` format is `<server>__<action>`, all lowercase snake_case
- `tool.description` must be a TSDoc `/** */` block comment
- `execution.env.fromParams` env var names use UPPER_SNAKE_CASE; add `TOOL_` prefix when clashing with reserved names (`PATH`, `HOME`, `USER`, etc.)
- `execution.compatibility` is optional compatibility metadata; if present, `targets` must be a non-empty array and each target's `os`, `kernel`, `arch` must be non-empty strings
- `targets[].support` is optional and only allows `tested` or `declared`; `targets[].notes` is optional and must be a string
- If a target is marked `support: tested`, a corresponding per-target smoke test must exist under the bundle's `scripts/`: `{prefix}__smoke_test__{kernel}_{arch}.sh` (e.g. `brew__smoke_test__darwin_arm64.sh`)
- **`execution.command` is forbidden** when args contain shell operators (`&&`, `||`, `;`, `|`, `>`, `<`); multi-step logic must use `execution.script`
- Each YAML defines exactly one tool
- `execution.env.fromRuntime` supports a string array, resolved left-to-right with short-circuit; ideal for expressing group-level to global-level fallback chains
- `execution.taskMode` controls execution mode: `sync` (default, returns result synchronously) or `async` (background task, returns `taskId` immediately; query status via Task management tools)

### 1.1 Compatibility Metadata

`execution.compatibility.targets` declares "known runtime targets", not a "hard platform gate".

- Declare each target as a complete tuple to avoid generating incorrect cartesian products by splitting `os`, `kernel`, `arch` into separate lists.
- `support: tested` means the target has actual validation evidence; omitting it or using `declared` means the target is claimed to work, but the repository does not use this field as a runtime enforcement condition.
- The evidence for `support: tested` is a per-target smoke test script: `{prefix}__smoke_test__{kernel}_{arch}.sh`; lint verifies its existence.
- The current loader and lint validate the field structure, but the server startup and tool exposure logic do not perform platform filtering based on this field.

### 1.2 Health Check Contract

The `__healthz` tool's responsibility is **dependency availability probing**, not business execution.

- Goal: quickly determine whether the key runtime dependencies of a command bundle are present and callable.
- Output semantics: `status=success` means dependencies are available; `status=error` means a dependency is missing or not callable.
- Failure boundary: a healthz failure only indicates that the bundle's runtime requirements are not met in the current environment; it must not masquerade as success.
- Design requirement: healthz must stay lightweight and idempotent, with no side effects.

### 1.3 Zero-Parameter Tool Rule

For zero-parameter tools (e.g. healthz), the YAML input contract must satisfy:

- `tool.input` must exist and be a mapping (object).
- `tool.input.properties` must exist and be a mapping; empty object is allowed.
- `tool.input.required` should be an empty list for zero-parameter tools.
- Introducing dummy parameters just to "pass validation" is not allowed.

Lint alignment rules:

- Lint validates the **existence and type** of `tool.input.properties`, no longer enforcing non-empty.
- This ensures zero-parameter tools are expressed legally and consistently with their runtime behavior.

For the full spec, see [`shell_as_mcp_defs/runprompt__generate_artifact/prompts/type-specs/shell-as-mcp-yaml.spec.md`](shell_as_mcp_defs/runprompt__generate_artifact/prompts/type-specs/shell-as-mcp-yaml.spec.md).

### 1.4 `__mcp_response_mode` Parameter

Every tool has an implicitly injected optional parameter `__mcp_response_mode`:

| Value | Description |
| --- | --- |
| `content` (default) | Returns result via the MCP `content` field |
| `structuredContent` | Returns result via the MCP `structuredContent` field |

Typically you do not need to pass this explicitly; the default `content` mode is sufficient.

---

## 2) Developing shell_as_mcp_defs

Each subdirectory under `shell_as_mcp_defs/` is a **command bundle** with the following layout:

```
shell_as_mcp_defs/<server>/
  spec_yaml/          # one YAML definition file per tool
  scripts/            # one .sh script per tool (referenced by execution.script.path in the YAML)
  prompts/            # optional: runprompt prompt templates
```

**Manual development workflow:**

1. Create `<server>__<action>.yaml` under `spec_yaml/`, following the §1 spec
2. Create the matching `.sh` under `scripts/`, reading params via `$TOOL_*` env vars
3. Run `bash scripts/lint/lint_all.sh` to validate

**Generating via `runprompt__generate_artifact`:**

> ⚠️ **Work in Progress (WIP)**: The auto-generation feature of `runprompt__generate_artifact` is still under development and not yet stable. The spec documents under `type-specs/` can be used directly as a reference for manual development, but relying on this tool to auto-generate bundles in production is not recommended.

`runprompt__generate_artifact` lets an LLM generate a complete bundle (YAML + scripts + optional prompts) in one shot, with the output automatically written to `SHELL_AS_MCP_SPEC_DIR/<server_name>/`.

> **Guidance for LLMs developing a new bundle (AI prompt)**
>
> When developing a new `shell_as_mcp_defs` bundle:
>
> 1. Full spec is in `shell_as_mcp_defs/runprompt__generate_artifact/prompts/type-specs/`:
>    - `shell-as-mcp-yaml.spec.md` — YAML structure and forbidden patterns
>    - `script.spec.md` — corresponding shell script spec
>    - `runprompt-prompt.spec.md` — runprompt prompt spec
> 2. Reference existing bundle examples: `brew/`, `ytdlp/`, `host_info/`, `ffmpeg/`
> 3. All tool input params must be mapped to UPPER_SNAKE_CASE env vars via `execution.env.fromParams` with `TOOL_` prefix; scripts only read `$TOOL_*`, never `$1`
> 4. Validate params early in scripts (fail fast); sensitive operations must be re-authorized inside the script and must not rely on the caller for authorization
> 5. `execution.command` is only for single-line static commands; multi-step logic must always use `execution.script`

---

## 3) Built-in Tools

> All bundles are under `shell_as_mcp_defs/` and loaded from `SHELL_AS_MCP_SPEC_DIR` at startup.

### 3.1 host_info

| Tool | Description |
| --- | --- |
| `host_info__healthz` | Probes whether host_info bundle runtime dependencies are available |
| `host_info__get_host_context` | Collects host system context (OS, locale, timezone, hardware, ~35 dev tool versions); ideal as the first call before code execution tasks |

**Parameters:**

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `include_hardware` | boolean | No | Whether to include CPU count and memory size; default `true` |
| `filter_tools` | string | No | Comma-separated tool names (e.g. `python3,node`); empty = check all |
| `output_format` | string | No | `pretty` (default) or `compact` |

---

### 3.2 ffmpeg

| Tool | Description | Required Params | Optional Params |
| --- | --- | --- | --- |
| `ffmpeg__healthz` | Probes whether ffmpeg bundle runtime dependencies (ffmpeg/ffprobe) are available | — | — |
| `ffmpeg__process_video_for_llm` | Video preprocessing (trim/scale/fps/speed/strip audio/watermark) | `input_path`, `output_path` | `start_time`, `end_time`, `max_resolution`, `fps`, `speed_factor`, `strip_audio`, `watermark_path` |
| `ffmpeg__process_audio_for_stt` | Audio preprocessing (segment/resample/mono/silence removal) | `input_path`, `output_path` | `start_time`, `end_time`, `sample_rate`, `channels`, `remove_silence`, `audio_format` |
| `ffmpeg__extract_frames_for_vision` | Frame extraction for vision (low fps or keyframes) | `input_path` | `output_dir`, `start_time`, `end_time`, `fps`, `keyframes_only`, `max_resolution` |
| `ffmpeg__create_video_summary` | Montage summary video (multi-input sampling and concatenation) | `input_paths`, `output_path` | `interval_sec`, `clip_duration_sec`, `merge_audio` |

### 3.2.1 ffmpeg Output Directory Defaults

Currently applies only to `ffmpeg__extract_frames_for_vision`.

Priority order:

1. Explicit parameter `output_dir`
2. Group-level env var `FFMPEG_OUTPUT_DIR`
3. Global env var `SHELL_AS_MCP_OUTPUT_DIR`

The tool's "directory output" contract remains unchanged; this only allows the default directory to be sourced from the runtime environment when no explicit parameter is passed.

---

### 3.3 brew

> ⚠️ `brew__install` / `brew__uninstall` / `brew__upgrade` require `confirm_action=true` to authorize execution; the script will also prompt a native macOS authorization dialog.

| Tool | Description | Required Params | Optional Params |
| --- | --- | --- | --- |
| `brew__healthz` | Probes whether brew bundle runtime dependencies (Homebrew) are available | — | — |
| `brew__info` | Query formula/cask details (version, dependencies, homepage) | `package_name` | `cask` |
| `brew__search` | Search packages | `query` | `include_casks` |
| `brew__list_installed` | List installed packages | — | `cask_only`, `formula_only` |
| `brew__install` | Install a formula/cask | `package_name`, `confirm_action` | `cask` |
| `brew__uninstall` | Uninstall a formula/cask | `package_name`, `confirm_action` | `cask`, `force` |
| `brew__upgrade` | Upgrade a formula/cask | `package_name`, `confirm_action` | `cask` |

---

### 3.4 ytdlp

> The `cookies` parameter accepts a path to a Netscape-format cookies file. You can also run `ytdlp__setup_cookies` first to encrypt and store cookies; subsequent tools will automatically fall back to these stored cookies when `cookies` is not specified.

| Tool | Description | Required Params | Optional Params |
| --- | --- | --- | --- |
| `ytdlp__healthz` | Probes whether ytdlp bundle runtime dependencies (yt-dlp) are available | — | — |
| `ytdlp__setup_cookies` | Guides macOS users through exporting cookies via a browser extension and encrypts/saves them (macOS only) | — | `overwrite` |
| `ytdlp__download_video` | Download video (supports resolution selection and time-range clipping) | `url` | `resolution`, `startTime`, `endTime`, `output_dir`, `cookies`, `proxy` |
| `ytdlp__download_audio` | Download audio | `url` | `output_dir`, `cookies`, `proxy` |
| `ytdlp__download_transcript` | Download subtitle text content | `url` | `language`, `cookies`, `proxy` |
| `ytdlp__download_video_subtitles` | Download subtitle files | `url` | `language`, `output_dir`, `cookies`, `proxy` |
| `ytdlp__list_subtitle_languages` | List available subtitle languages for a video | `url` | `cookies`, `proxy` |
| `ytdlp__get_video_metadata` | Retrieve full video metadata as JSON | `url` | `fields`, `cookies`, `proxy` |
| `ytdlp__get_video_metadata_summary` | Retrieve video metadata summary (title/duration/channel/etc.) | `url` | `cookies`, `proxy` |
| `ytdlp__get_video_comments` | Retrieve comment list | `url` | `maxComments`, `sortOrder`, `cookies`, `proxy` |
| `ytdlp__get_video_comments_summary` | Retrieve comment summary | `url` | `maxComments`, `cookies`, `proxy` |
| `ytdlp__search_videos` | Search videos | `query` | `maxResults`, `offset`, `response_format`, `uploadDateFilter`, `cookies`, `proxy` |

### 3.4.1 Output Directory Priority

Applies only to ytdlp download tools: `ytdlp__download_video`, `ytdlp__download_audio`, `ytdlp__download_video_subtitles`.

Priority order:

1. Explicit parameter `output_dir`
2. Group-level env var `YTDLP_OUTPUT_DIR`
3. Global env var `SHELL_AS_MCP_OUTPUT_DIR`
4. Historical default `~/Downloads`

Scripts uniformly read `TOOL_OUTPUT_DIR`; the bundle handles the mapping via `execution.env.fromRuntime` and `execution.env.fromParams`. This does not change the existing semantics of `output_path` / `output_dir`; it merely adds default value sources for download tools.

---

### 3.5 shell

| Tool | Description | Required Params | Optional Params |
| --- | --- | --- | --- |
| `shell__healthz` | Probes whether shell bundle base runtime (bash) is available | — | — |
| `shell__run_script_echo` | Runs a local script and echo-prefixes the input value (for development debugging) | `value` | — |

---

### 3.6 advanced_substation_alpha_ass

Advanced SubStation Alpha (ASS) subtitle format toolkit.

| Tool | Description | Required Params | Optional Params |
| --- | --- | --- | --- |
| `ass__healthz` | Probes whether ASS bundle runtime dependencies (ffmpeg) are available | — | — |
| `ass__create_template` | Creates a new ASS v4.00+ subtitle template file (with Default/Title/Note styles) | `output_path` | `title`, `play_res_x`, `play_res_y`, `overwrite` |
| `ass__get_spec` | Returns the ASS format specification document (read-only reference tool) | — | `section` |
| `ass__lint` | Validates/lints an ASS subtitle file (16 structural rules) | `ass_file_path` | `strict` |
| `ass__smoke_test` | Renders a test video to verify ASS subtitle renderability (requires ffmpeg) | `ass_file_path`, `output_path` | `duration_sec`, `resolution`, `background_color` |

---

### 3.7 runprompt__generate_artifact

> ⚠️ **Work in Progress (WIP)**: The auto-generation feature is still under development and not yet stable.

| Tool | Description | Required Params | Optional Params |
| --- | --- | --- | --- |
| `runprompt__healthz` | Probes whether runprompt bundle runtime prerequisites (python3) are available | — | — |
| `runprompt__generate_artifact` | Uses runprompt + LLM to auto-generate a complete shell-as-mcp bundle under `SHELL_AS_MCP_SPEC_DIR` | `artifact_type`, `requirements` | `server_name`, `tool_name`, `max_repair_rounds`, `run_tests`, `run_code_review`, `run_security_review` |

---

### 3.8 run_safe_command

> ⚠️ `run_safe_command__execute` runs the specified executable **without shell eval** in a validated working directory. On darwin/arm64, pre-execution authorization uses native Swift+WKWebView and automatically falls back to OSA. All executions are written to a structured audit log.

| Tool | Description | Required Params | Optional Params |
| --- | --- | --- | --- |
| `run_safe_command__healthz` | Probes whether run_safe_command runtime dependencies and platform capabilities are available | — | — |
| `run_safe_command__execute` | Executes a command without shell eval; records structured security and audit metadata | `command`, `args_json`, `working_dir` | — |
| `run_safe_command__help` | Shows usage and safety model for the run_safe_command bundle | — | `topic` |
| `run_safe_command__audit_get` | Reads recent execution audit records | — | `limit`, `include_rotated`, `rotated_file_limit` |
| `run_safe_command__audit_rotate` | Rotates the audit file and enforces retention | — | `max_files` |

---

## 4) Running

```bash
npm install
npm run build
npm start
```

### 4.1 Launch via GitHub npx -y (stdio)

```bash
npx -y github:meomeo-dev/shell-as-mcp --transport stdio
```

If you use the `runprompt__generate_artifact` tool, install `runprompt` separately:

```bash
# Using uv (recommended)
uv pip install git+https://github.com/chr15m/runprompt
# Using pip
pip install "git+https://github.com/chr15m/runprompt.git"
```

### 4.2 Startup Options & Environment Variables

| Option | Env Var | Default | Description |
| --- | --- | --- | --- |
| `--transport` | `SHELL_AS_MCP_TRANSPORT` | `stdio` | `stdio` or `streamable-http` |
| `--spec-dir` | `SHELL_AS_MCP_SPEC_DIR` | `./shell_as_mcp_defs` | YAML spec directory (overlay) |
| `--host` | `SHELL_AS_MCP_HTTP_HOST` | `127.0.0.1` | HTTP listen address |
| `--port` | `SHELL_AS_MCP_HTTP_PORT` | `3001` | HTTP listen port |
| `--http-path` | `SHELL_AS_MCP_HTTP_PATH` | `/mcp` | HTTP path |
| `--max-concurrent-tasks` | `SHELL_AS_MCP_MAX_CONCURRENT_TASKS` | — (unlimited) | Max concurrent background async tasks |
| — | `SHELL_AS_MCP_SERVER_NAME` | `shell-as-mcp` | MCP server name |
| — | `SHELL_AS_MCP_SERVER_VERSION` | `package.json` version | MCP server version |

### 4.3 Built-in Spec vs. Overlay Directory

The tools in the built-in `shell_as_mcp_defs/` are **always loaded directly from the package**. `SHELL_AS_MCP_SPEC_DIR` is an **overlay directory** that additionally loads tools from it; tools with the same name as built-in ones are overridden by the user directory.

- The default value is `./shell_as_mcp_defs` (loaded only once when it matches the built-in path).

---

## 5) mcpServers Configuration

### 5.1 stdio (recommended for local use)

```json
{
  "mcpServers": {
    "shell-as-mcp": {
      "command": "npx",
      "args": ["-y", "github:meomeo-dev/shell-as-mcp", "--transport", "stdio"],
      "env": {
        "SHELL_AS_MCP_SPEC_DIR": "/absolute/path/to/specs",
        "RUNPROMPT_MODEL": "openrouter/deepseek/deepseek-v3.2",
        "RUNPROMPT_BASE_URL": "https://openrouter.ai/api/v1",
        "RUNPROMPT_OPENROUTER_API_KEY": "sk-or-v1-xxxx",
        "https_proxy": "http://127.0.0.1:8890",
        "HTTPS_PROXY": "http://127.0.0.1:8890"
      }
    }
  }
}
```

### 5.2 streamable-http

```json
{
  "mcpServers": {
    "shell-as-mcp-http": {
      "command": "npx",
      "args": [
        "-y", "github:meomeo-dev/shell-as-mcp",
        "--transport", "streamable-http",
        "--host", "127.0.0.1",
        "--port", "3001",
        "--http-path", "/mcp"
      ],
      "env": {
        "SHELL_AS_MCP_SPEC_DIR": "/absolute/path/to/specs",
        "SHELL_AS_MCP_SERVER_NAME": "shell-as-mcp-http"
      }
    }
  }
}
```

### 5.3 Available Environment Variables

All of the following env vars can be placed directly in `mcpServers.<name>.env`.

#### Server Startup

| Env Var | Purpose | Default |
| --- | --- | --- |
| `SHELL_AS_MCP_TRANSPORT` | Transport mode: `stdio` or `streamable-http` | `stdio` |
| `SHELL_AS_MCP_SPEC_DIR` | Overlay spec directory | `./shell_as_mcp_defs` |
| `SHELL_AS_MCP_HTTP_HOST` | HTTP listen address | `127.0.0.1` |
| `SHELL_AS_MCP_HTTP_PORT` | HTTP listen port | `3001` |
| `SHELL_AS_MCP_HTTP_PATH` | HTTP path | `/mcp` |
| `SHELL_AS_MCP_SERVER_NAME` | MCP server name | `shell-as-mcp` |
| `SHELL_AS_MCP_SERVER_VERSION` | MCP server version | `package.json` version |
| `SHELL_AS_MCP_MAX_CONCURRENT_TASKS` | Max concurrent background async tasks | — (unlimited) |

#### Output Directory Defaults

| Env Var | Purpose | Applicable Tools |
| --- | --- | --- |
| `SHELL_AS_MCP_OUTPUT_DIR` | Global output directory fallback | `ytdlp__download_video`, `ytdlp__download_audio`, `ytdlp__download_video_subtitles`, `ffmpeg__extract_frames_for_vision` |
| `YTDLP_OUTPUT_DIR` | ytdlp group-level output directory | `ytdlp__download_video`, `ytdlp__download_audio`, `ytdlp__download_video_subtitles` |
| `FFMPEG_OUTPUT_DIR` | ffmpeg group-level output directory | `ffmpeg__extract_frames_for_vision` |

#### runprompt Generation

| Env Var | Purpose | Fallback |
| --- | --- | --- |
| `RUNPROMPT_MODEL` | LLM model name | `MODEL` |
| `RUNPROMPT_BASE_URL` | API Base URL | `OPENAI_BASE_URL`, `OPENAI_API_BASE`, `BASE_URL` |
| `RUNPROMPT_OPENROUTER_API_KEY` | API Key | `OPENROUTER_API_KEY`, `API_KEY` |
| `RUNPROMPT_DEBUG_PROMPT` | Print the full rendered prompt and enable verbose debug before the request | — |
| `SHELL_AS_MCP_RUNPROMPT_DIAGNOSTIC` | Output runprompt startup diagnostics | — |
| `SHELL_AS_MCP_RUNPROMPT_TIMEOUT_SEC` | Timeout in seconds for the runprompt Python layer | `120` |
| `SHELL_AS_MCP_RUNPROMPT_TOOL_ROOT` | Root directory for runprompt file tools | Rarely needs manual configuration |

#### Network Proxy

| Env Var | Purpose |
| --- | --- |
| `https_proxy` | Lowercase HTTPS proxy env var |
| `HTTPS_PROXY` | Uppercase HTTPS proxy env var |

In short: if you just run the server normally, you typically only need `SHELL_AS_MCP_SPEC_DIR`; if you need file output, also add `SHELL_AS_MCP_OUTPUT_DIR` or the group-level directory vars; if you use `runprompt__generate_artifact`, also supply the `RUNPROMPT_*` vars.

**`runprompt__generate_artifact` environment variables (⚠️ auto-generation is WIP):**

| Var | Description | Fallback |
| --- | --- | --- |
| `RUNPROMPT_MODEL` | LLM model name | `MODEL` |
| `RUNPROMPT_BASE_URL` | API Base URL | `OPENAI_BASE_URL`, `OPENAI_API_BASE`, `BASE_URL` |
| `RUNPROMPT_OPENROUTER_API_KEY` | API Key | `OPENROUTER_API_KEY`, `API_KEY` |

Debug tip: set `RUNPROMPT_DEBUG_PROMPT=1` to print the full rendered prompt before the request and enable `runprompt -v`.

---

## 6) Testing & Lint

```bash
# Unit tests
npm test

# Run smoke tests (generic + current-target)
bash scripts/run_smoke_tests.sh

# Build + pack + strict protocol handshake smoke in one command
make regress-pack-smoke

# Lint (YAML spec + shellcheck + prompt format; full scan of shell_as_mcp_defs/)
bash scripts/lint/lint_all.sh
```

`lint_all.sh` auto-discovers and validates five categories:

- `spec_yaml/*.yaml` → `validate_shell_as_mcp_yaml.sh` (structure/fields/forbidden patterns)
- `scripts/*.sh` → `validate_script.sh` (shellcheck)
- `prompts/*.prompt` (not starting with `_`) → `validate_runprompt_prompt.sh` (frontmatter/schema)
- `spec_yaml/*.yaml` (containing `support: tested`) → `validate_tested_has_smoke_test.sh` (verifies the corresponding per-target smoke test exists)
- `SKILL.md` → `validate_skill_md.sh` (frontmatter and structure)

`run_smoke_tests.sh` first runs each bundle's generic smoke test (`*__smoke_test.sh`), then auto-discovers and runs the per-target smoke test matching the current platform (e.g. `*__smoke_test__darwin_arm64.sh`).

`make regress-pack-smoke` runs build, npm pack, starts the server in streamable-http mode from the tarball, and validates the strict handshake sequence: `initialize`, `notifications/initialized`, `tools/list`.

Single-file validation:

```bash
bash scripts/lint/validate_shell_as_mcp_yaml.sh shell_as_mcp_defs/brew/spec_yaml/brew__info.yaml
bash scripts/lint/validate_script.sh shell_as_mcp_defs/brew/scripts/brew__info.sh
bash scripts/lint/validate_tested_has_smoke_test.sh shell_as_mcp_defs/brew/spec_yaml/brew__info.yaml
```

### 6.1 Make Shortcuts

```bash
make build    # clean + compile TypeScript + copy runtime assets
make test     # equivalent to npm test (unit + e2e)
make lint     # equivalent to bash scripts/lint/lint_all.sh
make deps     # npm ci to install dependencies
make help     # show all available make targets
```

### 6.2 Docker

```bash
# Build image
make docker-build

# Run container (stdio mode)
make docker-run

# Enter container shell for debugging
make docker-shell
```

---

## Acknowledgements

This project builds on top of the following excellent open-source projects:

- [**@modelcontextprotocol/sdk**](https://github.com/modelcontextprotocol/typescript-sdk) — TypeScript MCP SDK providing standardized MCP server protocol implementation
- [**runprompt**](https://github.com/chr15m/runprompt) — CLI LLM prompt runner powering the `runprompt__generate_artifact` bundle
- [**dotprompt**](https://github.com/google/dotprompt) — Google's structured prompt format specification, influencing this project's prompt template design

## License

MIT — see [LICENSE](LICENSE) for details.
