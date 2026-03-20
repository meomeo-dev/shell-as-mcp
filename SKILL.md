---
name: shell-as-mcp
description: Develop, test, and manage shell command bundles as standard MCP tools via YAML + Bash. Use when creating a new command bundle, adding or modifying individual tools, debugging YAML spec or script issues, running quality gates, or deploying the server.
given-when-to:
   - given: User asks to create a new shell-as-mcp command bundle
     when_to: Use this skill to define YAML specs, companion scripts, and validation flow
   - given: User asks to add or modify tools in an existing bundle
     when_to: Use this skill to apply naming, parameter mapping, and smoke test rules
   - given: User reports YAML spec or script execution issues
     when_to: Use this skill to diagnose schema/script problems and run quality gates
   - given: User asks to run release readiness checks before merge or deployment
     when_to: Use this skill to run lint, tests, smoke checks, and build verification
version: 1.0.0
---

# shell-as-mcp

TypeScript MCP server that maps shell commands to standard MCP tools via single-file YAML specs + Bash scripts.
Each tool is defined by one YAML file and one companion `.sh` script; no code changes to the server are needed.

## Architecture

```
YAML spec (spec_yaml/*.yaml)
  └─ tool.input         → MCP input schema
  └─ execution.env.fromParams → UPPER_SNAKE_CASE env vars
                                    │
              ┌─────────────────────┘
              ▼
  Bash script (scripts/*.sh)
    reads ${TOOL_*} env vars
    performs shell logic
    writes to stdout (result) / stderr (error)
              │
              ▼
  executor.ts → MCP tool response (status, stdout, stderr, exit_code, ...)
```

Bundle directory structure:

```
shell_as_mcp_defs/<bundle>/
  spec_yaml/            # one YAML file per tool
  scripts/              # one .sh file per tool (+ optional smoke test scripts)
  prompts/              # optional: runprompt prompt templates
```

## Scope

This skill ONLY:
- Guides authoring YAML specs and companion Bash scripts
- References tracked project files (`shell_as_mcp_defs/`, `src/`, `scripts/`)
- Provides quality gate commands and workflow steps

This skill NEVER:
- Executes tools on behalf of the user without explicit request
- Modifies installed system packages autonomously
- Accesses files outside the project directory or ignored by `.gitignore`
- Takes destructive action without confirmation

## Core Rules

### 1. One YAML per Tool
Each tool gets exactly one YAML file: `spec_yaml/<bundle>__<action>.yaml`.  
Root keys MUST include: `apiVersion: v1`, `tool`, `execution`.

### 2. Tool Naming
`tool.name` MUST be `<bundle>__<action>` in snake_case. Examples: `brew__install`, `ffmpeg__extract_frames_for_vision`.

### 3. Description Format (TSDoc)
`tool.description` MUST be a valid TSDoc block comment (`/** ... */`).  
Include a one-line summary and `@param` for each input parameter.  
NEVER use `docstring` — the loader will reject it.

### 4. Parameter Flow via Environment Variables
Map ALL tool input parameters through `execution.env.fromParams` as `UPPER_SNAKE_CASE` env vars.  
Scripts read exclusively via `${TOOL_PARAM_NAME:?required}`.  
NEVER read `$1`, `$2`, or other positional args from within a tool script.

### 5. Script Header & Fail Fast
Every script MUST start with:
```bash
#!/usr/bin/env bash
set -euo pipefail
```
Validate all parameters immediately: use `:?` to reject empty/missing values.  
Sanitize user-supplied strings via allowlist regex before any shell expansion.

### 6. Use `execution.script` for Multi-Step Logic
`execution.command` is only for a single static executable + fixed args.  
NEVER put `&&`, `||`, `;`, `|`, `>`, `<` inside `execution.command.args`.  
If multi-step logic is needed, use `execution.script.path`.

### 7. Compatibility Targets Are Complete Tuples
If `execution.compatibility.targets` is present, every target MUST include `os`, `kernel`, and `arch`.  
`support: tested` requires a matching per-target smoke test script: `scripts/<bundle>__smoke_test__{kernel}_{arch}.sh`.

### 8. Zero-Parameter Tools
Tools with no inputs MUST have:
```yaml
tool:
  input:
    properties: {}
    required: []
```
NEVER add dummy parameters to pass lint.

### 9. Healthz Contract
Every bundle SHOULD include a `<bundle>__healthz` tool.  
It MUST be lightweight, idempotent, and side-effect-free.  
Output `status: success` when dependencies are available; `status: error` when not.

## Workflow

Follow these steps to add a tool:

1. **Create YAML spec**
   ```
   shell_as_mcp_defs/<bundle>/spec_yaml/<bundle>__<action>.yaml
   ```
   Copy and adapt from `shell_as_mcp_defs/brew/spec_yaml/brew__info.yaml`.

2. **Create Bash script**
   ```
   shell_as_mcp_defs/<bundle>/scripts/<bundle>__<action>.sh
   ```
   First two lines: `#!/usr/bin/env bash` + `set -euo pipefail`.
   Read params via `${TOOL_*:?}`. Validate before use.

3. **Run lint**
   ```bash
   make lint
   # or: bash scripts/lint/lint_all.sh
   # single-file: bash scripts/lint/validate_shell_as_mcp_yaml.sh <yaml>
   ```

4. **Add smoke test** (required for `support: tested` targets)
   ```
   scripts/<bundle>__smoke_test.sh              # generic
   scripts/<bundle>__smoke_test__darwin_arm64.sh  # per-target example
   ```

5. **Run unit + integration tests**
   ```bash
   npm test
   ```

6. **Run regression smoke**
   ```bash
   make regress-pack-smoke
   ```

7. **Build**
   ```bash
   make build
   ```

8. **Start server**
   ```bash
   npm start                                          # stdio (default)
   npm start -- --transport streamable-http --port 3001  # HTTP
   ```

## Quality Gates

| Gate | Command | What it checks |
|------|---------|----------------|
| Lint | `make lint` | YAML structure, TSDoc format, script syntax (shellcheck), smoke test naming consistency |
| Unit tests | `npm test` | executor, spec-loader, schema, task-store, mcp-response modules |
| Regression smoke | `make regress-pack-smoke` | full pack + streamable-http handshake + per-target smoke tests |
| Build | `make build` | TypeScript compile, asset copy to `dist/` |

## Resources

**Specs and reference docs**
- `shell_as_mcp_defs/runprompt__generate_artifact/prompts/type-specs/shell-as-mcp-yaml.spec.md` — full YAML spec with all fields and forbidden patterns
- `shell_as_mcp_defs/runprompt__generate_artifact/prompts/type-specs/script.spec.md` — Bash script spec
- `shell_as_mcp_defs/runprompt__generate_artifact/prompts/type-specs/claude-skill.spec.md` — SKILL.md authoring spec

**Server source**
- `src/index.ts` — MCP server entry, transport init, tool registration
- `src/executor.ts` — shell execution, env building, timeout/output management
- `src/spec-loader.ts` — YAML discovery and loading
- `src/types.ts` — TypeScript data models
- `src/startup-options.ts` — CLI flags and env var reference
- `src/task-manager.ts` + `src/task-store.ts` — async background task management

**Bundle examples**
- `shell_as_mcp_defs/brew/` — package management (install, uninstall, search, healthz)
- `shell_as_mcp_defs/ffmpeg/` — video/audio processing
- `shell_as_mcp_defs/ytdlp/` — video download
- `shell_as_mcp_defs/host_info/` — system context probe
- `shell_as_mcp_defs/shell/` — base shell scripting utilities
- `shell_as_mcp_defs/advanced_substation_alpha_ass/` — ASS subtitle format toolkit
- `shell_as_mcp_defs/runprompt__generate_artifact/` — LLM-powered bundle auto-generation (WIP)
- `shell_as_mcp_defs/run_safe_command/` — no-eval command execution with audit logging

**Lint scripts**
- `scripts/lint/lint_all.sh` — lint entry point
- `scripts/lint/validate_shell_as_mcp_yaml.sh` — YAML validator
- `scripts/lint/validate_script.sh` — Bash script validator
- `scripts/lint/validate_runprompt_prompt.sh` — runprompt prompt frontmatter/schema validator
- `scripts/lint/validate_skill_md.sh` — SKILL.md structure and frontmatter validator
- `scripts/lint/validate_tested_has_smoke_test.sh` — verifies per-target smoke test exists for `support: tested` targets

**Project root**
- `README.md` — full specification walkthrough and env var reference
- `Makefile` — all dev commands (`build`, `test`, `lint`, `regress-pack-smoke`)
- `package.json` — npm scripts and dependency list

## Security & Privacy

- **Fail fast on parameters**: use `:?` bash expansion; never silently allow empty inputs
- **Allowlist validation**: validate user-controlled strings via regex before shell expansion (prevent injection)
- **Sensitive operations**: destructive commands (`brew__install`, `brew__uninstall`) require `confirm_action=true` explicitly and trigger native macOS authorization dialogs inside the script — never bypass these
- **No secrets in YAML**: API keys and tokens go in startup env vars, not in `execution.env.static` committed to the repo
- **Smoke tests are read-only**: must not make network requests, install packages, or write files
