# Artifact Spec: claude-skill

Goal: generate one valid `SKILL.md` document for Claude-style skills, aligned with this repository's spec style and project-file reference constraints.

## Required output contract

1. Output MUST be raw Markdown only (no extra prose outside the file content).
2. The artifact filename SHOULD be `SKILL.md`.
3. Content MUST use two parts:
   - YAML frontmatter (`---` ... `---`)
   - Markdown body

## Frontmatter schema

| Field | Type | Required | Constraints | Description |
|------|------|------|------|------|
| `name` | `string` | Yes | kebab-case (`[a-z0-9-]+`) | Skill identifier and slash command name basis |
| `description` | `string` | Yes | MUST contain capability summary; MAY include `Use when...` phrase | What this skill does at a high level |
| `given-when-to` | `array<object>` | No | Each item SHOULD include `given` and `when_to` | Semantic invocation hints for LLM routing (preferred over rigid trigger keywords) |
| `disable-model-invocation` | `boolean` | No | default false | If true, disable model auto-invocation |
| `model` | `string` | No | non-empty | Optional model hint |
| `version` | `string` | No | semantic or project-defined | Optional version marker |
| `homepage` | `string` | No | URL format preferred | Optional human reference |
| `metadata` | `object` | No | JSON/YAML mapping | Optional extra metadata |
| `changelog` | `string` | No | short text preferred | Optional latest change summary |

## Body structure requirements

A generated `SKILL.md` SHOULD include the following sections in order:

1. `# <Skill Title>`
2. `## Scope`
3. `## Core Rules`
4. `## Workflow`
5. `## Security & Privacy` (recommended)
6. `## Resources` (optional when no references are needed)

### Section intent

- `given-when-to` (frontmatter): express semantic invocation conditions.
- `Scope`: define what the skill can and cannot do.
- `Core Rules`: enumerate MUST/SHOULD behavior gates.
- `Workflow`: provide deterministic step flow.
- `Resources`: list local project files and their purpose.

## Rules

1. `name` MUST be stable and kebab-case; avoid spaces and uppercase.
2. `description` MUST contain a concise capability summary.
3. Invocation semantics SHOULD be expressed in frontmatter `given-when-to` (semantic phrasing preferred).
4. Body rules SHOULD be imperative (verb-first), concise, and testable.
5. `Core Rules` SHOULD contain at least 3 enforceable rules.
6. Workflow MUST be sequential and unambiguous.
7. If references are present, each reference MUST include a repository-relative path.
8. References MUST point to existing or planned tracked project files only.
9. References MUST NOT point to paths ignored by `.gitignore`.
10. References MUST NOT use machine-local absolute paths.
11. If a path may contain sensitive data, the skill MUST require explicit user consent before reading.

### `given-when-to` pattern (recommended)

```yaml
given-when-to:
   - given: User asks to build or extend API endpoints in a TypeScript service
      when_to: Use this skill to drive design -> implementation -> tests workflow
   - given: User reports schema mismatch or contract drift
      when_to: Use this skill to align OpenAPI contracts and regression tests
```

## Project file reference policy

Allowed reference patterns (examples):
- `README.md`
- `src/index.ts`
- `shell_as_mcp_defs/runprompt__generate_artifact/prompts/type-specs/script.spec.md`
- `docs/plans/2026-03-18-feature-design.md` (if tracked in repo)

Forbidden reference patterns (derived from `.gitignore`):
- `tasks/...`
- `tmp/...`
- `dist/...`
- `node_modules/...`
- `**/__pycache__/...`
- `__pycache__/...`
- `*.pyc`
- `*.pyo`
- `.env`
- `.vscode/...`
- `.idea/...`
- `*.swp`
- `*.swo`
- `.DS_Store`

## Good example

```markdown
---
name: api-development
description: Orchestrate API design, implementation, and verification. Use when building a new API, adding endpoints, or refactoring API contracts.
given-when-to:
   - given: User asks to create or evolve backend API contracts
      when_to: Apply this skill to run design -> implement -> test workflow
   - given: User asks to add endpoints with strict schema compatibility
      when_to: Use this skill to enforce contract-first development and tests
model: reasoning
---

# API Development

## Scope
This skill ONLY:
- Provides design-to-test workflow guidance.
- References tracked project files.

This skill NEVER:
- Uses ignored paths.
- Performs destructive actions without explicit approval.

## Core Rules
1. Define API contract before implementation.
2. Add tests before marking a task complete.
3. Keep error format consistent across endpoints.

## Workflow
Request -> Design -> Implement -> Test -> Review -> Deliver

## Security & Privacy
- Requires no special privileges by default.
- Avoid reading or writing sensitive paths unless user explicitly approves.

## Resources
- `README.md`: project entry context
- `src/index.ts`: runtime entrypoint
```

## Bad example

```markdown
---
name: API Helper
---

# API Helper

Check /Users/alice/private/todo.md and `dist/...` before coding.
```

Why invalid:
1. `name` is not kebab-case.
2. `description` is missing.
3. Uses machine-local absolute path.
4. References ignored `dist/...` path.

## Validation checklist

- [ ] Has valid YAML frontmatter with `name` and `description`.
- [ ] `name` matches kebab-case.
- [ ] Invocation semantics are present in frontmatter `given-when-to` or `description` (`Use when`).
- [ ] Body contains `Scope`, `Core Rules`, `Workflow`.
- [ ] `Core Rules` contains at least 3 enforceable rules.
- [ ] `Workflow` is sequential and unambiguous.
- [ ] Any `Resources` paths are repository-relative.
- [ ] No ignored-path reference from `.gitignore`.
- [ ] No absolute local path reference.
