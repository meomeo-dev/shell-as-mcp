# Artifact Spec: shell-as-mcp-yaml

Generate one valid shell-as-mcp tool YAML document.

## Required structure (canonical bundle example)

```yaml
apiVersion: v1
tool:
  name: <server>__<action>          # snake_case, e.g. demo_tree__get_tree
  description: |-
    /**
     * One-line summary.
     * @param param_name Description.
     */
  input:
    properties:
      param_name: { type: string, description: "..." }
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
    mode: direct
  env:
    fromParams:
      TOOL_PARAM_NAME: param_name   # UPPER_SNAKE_CASE env var <- tool param
  compatibility:
    targets:
      - os: macos
        kernel: darwin
        arch: arm64
        support: tested
        notes: Apple Silicon developer machine
  timeoutMs: 30000
  script:
    path: scripts/<tool_name>.sh    # relative path to companion script in bundle
    interpreter: bash
```

## Rules

1. Root keys MUST include: `apiVersion`, `tool`, `execution`.
2. `apiVersion` MUST be `v1`.
3. `tool.name` MUST match the tool_name provided in requirements (snake_case).
4. `tool.description` MUST be a valid TSDoc block comment (`/** ... */`).
5. `tool.input.properties` MUST exist and be a YAML object (mapping). If the tool has no input parameters, use `properties: {}` and `required: []`.
6. For tools that have input parameters, each parameter in `tool.input.properties` MUST define both `type` and `description`.
7. `tool.output` MUST contain all standard execution fields shown above.
8. **In shell-as-mcp-bundle context: ALWAYS use `execution.script`** — point `path` to `scripts/{tool_name}.sh`.
9. **Pass ALL tool parameters as environment variables** via `execution.env.fromParams`. Use UPPER_SNAKE_CASE names; avoid shell reserved names (`PATH`, `HOME`, `USER`, `IFS`, `PS1`). Prefix with `TOOL_` when in doubt.
10. `execution.compatibility` is optional metadata. If present, `targets` MUST be a non-empty array, and every target MUST include non-empty `os`, `kernel`, and `arch`. `support` is optional and limited to `tested` or `declared`; `notes` is optional string metadata.
11. If any `execution.compatibility.targets[*].support` is `tested`, the bundle MUST provide a per-target smoke test script named `{prefix}__smoke_test__{kernel}_{arch}.sh` in the bundle `scripts/` directory. Example: `brew__smoke_test__darwin_arm64.sh`.
12. In current repo conventions, smoke test prefix is anchored by a generic script `scripts/{prefix}__smoke_test.sh`; lint derives `{prefix}` from that anchor and then validates per-target scripts.
13. `execution.command` is for **single executable + static args only**. ALLOWED examples:
   ```yaml
   execution:
     command:
       executable: ffmpeg
       args: ["-version"]
   ```
   ```yaml
   execution:
     command:
       executable: echo
       args: ["hello", "world"]
   ```
14. **FORBIDDEN** — never use `execution.command` for any of the following patterns:
    - `args: ["-c", "cmd1 && cmd2"]` — bash/sh inline script via `-c` flag
    - `args: ["cmd1 && cmd2"]` — `&&` command chaining inside an arg
    - `args: ["cmd1 ; cmd2"]`  — `;` command chaining inside an arg
    - `args: ["cmd1 | cmd2"]`  — pipe chaining inside an arg
    - **General rule**: if any arg contains shell operators (`&&`, `||`, `;`, `|`, `>`, `<`, `` ` ``), it is FORBIDDEN.
    - **If multi-step logic is needed, use `execution.script`** (see Rule 7); the script file itself may contain arbitrary shell logic.
15. Output MUST be raw YAML only (no markdown fences, no explanation).
