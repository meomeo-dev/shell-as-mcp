import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, realpath, writeFile, chmod } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { executeFromSpec } from "../src/executor.js";
import { loadSpecs } from "../src/spec-loader.js";

const repoRoot = path.resolve(process.cwd());

async function loadRunpromptSpec() {
  const specs = await loadSpecs(path.join(repoRoot, "shell_as_mcp_defs"));
  const spec = specs.find((item) => item.tool.name === "runprompt__generate_artifact");
  assert.ok(spec, "runprompt__generate_artifact spec should exist");
  assert.ok(spec.execution.env);
  assert.ok(Object.prototype.hasOwnProperty.call(spec.execution.env, "static"));
  assert.deepEqual(spec.execution.env.static, {});
  const runtimeEnv = spec.execution.env.fromRuntime;
  assert.ok(runtimeEnv);
  assert.deepEqual(runtimeEnv.RUNPROMPT_MODEL, ["RUNPROMPT_MODEL", "MODEL"]);
  assert.deepEqual(runtimeEnv.RUNPROMPT_BASE_URL, [
    "RUNPROMPT_BASE_URL",
    "OPENAI_BASE_URL",
    "OPENAI_API_BASE",
    "BASE_URL",
  ]);
  assert.deepEqual(runtimeEnv.RUNPROMPT_OPENROUTER_API_KEY, [
    "RUNPROMPT_OPENROUTER_API_KEY",
    "OPENROUTER_API_KEY",
    "API_KEY",
  ]);
  assert.deepEqual(runtimeEnv.SHELL_AS_MCP_SANDBOX_ENABLE, ["SHELL_AS_MCP_SANDBOX_ENABLE"]);
  assert.deepEqual(runtimeEnv.SHELL_AS_MCP_FILESYSTEM_MCP_ENABLE, ["SHELL_AS_MCP_FILESYSTEM_MCP_ENABLE"]);
  assert.ok(!("model" in spec.tool.input.properties));
  assert.ok(!("base_url" in spec.tool.input.properties));
  assert.ok(!("openrouter_api_key" in spec.tool.input.properties));
  assert.ok(!("output_path" in spec.tool.input.properties));
  return spec;
}

function extractGeneratedBundlePath(stdout: unknown): string {
  const text = String(stdout ?? "");
  const match = text.match(/^generated_bundle:(.+)$/m);
  assert.ok(match, "stdout should include generated_bundle:<path>");
  return match[1].trim();
}

function extractQualityGates(stdout: unknown): Record<string, unknown> {
  const text = String(stdout ?? "");
  const match = text.match(/^quality_gates:(.+)$/m);
  assert.ok(match, "stdout should include quality_gates:<json>");
  return JSON.parse(match[1]);
}

test("runprompt template references per-type specification", async () => {
  const promptFile = path.join(repoRoot, "shell_as_mcp_defs", "runprompt__generate_artifact", "prompts", "generate_artifact.prompt");
  const scriptSpec = path.join(repoRoot, "shell_as_mcp_defs", "runprompt__generate_artifact", "prompts", "type-specs", "script.spec.md");
  const yamlSpec = path.join(repoRoot, "shell_as_mcp_defs", "runprompt__generate_artifact", "prompts", "type-specs", "shell-as-mcp-yaml.spec.md");
  const promptSpec = path.join(repoRoot, "shell_as_mcp_defs", "runprompt__generate_artifact", "prompts", "type-specs", "runprompt-prompt.spec.md");

  const promptText = await readFile(promptFile, "utf8");
  assert.match(promptText, /\{\{type_spec\}\}/);

  const [scriptText, yamlText, runpromptText] = await Promise.all([
    readFile(scriptSpec, "utf8"),
    readFile(yamlSpec, "utf8"),
    readFile(promptSpec, "utf8"),
  ]);

  assert.match(scriptText, /Artifact Spec: script/);
  assert.match(yamlText, /Artifact Spec: shell-as-mcp-yaml/);
  assert.match(runpromptText, /runprompt-prompt/);
  assert.match(runpromptText, /frontmatter/i);
  assert.match(runpromptText, /Handlebars/i);
  assert.match(runpromptText, /MUST 包含 `model` 字段/i);
});

test("runprompt wrapper supports shell-as-mcp-bundle generation", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-runprompt-"));
  const mockBinDir = path.join(tempDir, "bin");

  await mkdir(mockBinDir, { recursive: true });
  const mockRunpromptPath = path.join(mockBinDir, "runprompt");
  await writeFile(
    mockRunpromptPath,
    "#!/usr/bin/env bash\nset -euo pipefail\nif [[ \"$*\" == *plan_bundle* ]]; then\n  printf '%s\\n' '{\"tool_name\":\"demo_server__hello\",\"server_name\":\"demo_server\",\"description\":\"generated\",\"params\":[],\"script_behavior\":\"echo ok\",\"prompt_purpose\":\"template\"}'\nelif [[ \"$*\" == *code_review* ]] || [[ \"$*\" == *cross_file_consistency* ]] || [[ \"$*\" == *security_review_llm* ]]; then\n  printf '%s\\n' '{\"passed\":true,\"issues\":[],\"summary\":\"ok\"}'\nelif [[ \"$*\" == *summarize_failures* ]]; then\n  printf '%s\\n' '{\"repair_strategy\":\"retry generation\",\"files_to_fix\":[],\"issues_by_file\":{\"shell-as-mcp-yaml\":[],\"script\":[],\"runprompt-prompt\":[]},\"root_cause\":\"\"}'\nelif [[ \"${@: -1}\" == *'\"artifact_type\": \"shell-as-mcp-yaml\"'* ]]; then\n  cat <<'YAML'\napiVersion: v1\ntool:\n  name: generated__tool\n  description: generated\n  input:\n    properties: {}\n  output:\n    type: object\n    properties: {}\nexecution:\n  shell:\n    mode: direct\n  command:\n    executable: echo\n    args: [ok]\nYAML\nelif [[ \"${@: -1}\" == *'\"artifact_type\": \"runprompt-prompt\"'* ]]; then\n  cat <<'PROMPT'\n---\nmodel: openrouter/deepseek/deepseek-v3.2\n---\nHello {{name}}\nPROMPT\nelse\n  cat <<'SH'\n#!/usr/bin/env bash\nset -euo pipefail\necho ok\nSH\nfi\n",
    "utf8",
  );
  await chmod(mockRunpromptPath, 0o755);

  const spec = await loadRunpromptSpec();
  const originalPath = process.env.PATH ?? "";
  const originalSpecDir = process.env.SHELL_AS_MCP_SPEC_DIR;
  process.env.PATH = `${mockBinDir}:${originalPath}`;
  process.env.SHELL_AS_MCP_SPEC_DIR = tempDir;

  try {
    const result = await executeFromSpec(spec, {
      artifact_type: "shell-as-mcp-bundle",
      requirements: "create shell as mcp bundle",
      server_name: "demo_server",
      tool_name: "demo_server__hello",
      run_tests: false,
      max_repair_rounds: 0,
    });

    assert.equal(result.status, "success");
    const bundlePath = extractGeneratedBundlePath(result.stdout);
    const [resolvedBundlePath, resolvedTempDir] = await Promise.all([
      realpath(bundlePath),
      realpath(tempDir),
    ]);
    assert.ok(resolvedBundlePath.startsWith(path.join(resolvedTempDir, "demo_server")));

    const generatedYaml = path.join(bundlePath, "spec_yaml", "demo_server__hello.yaml");
    const generatedScript = path.join(bundlePath, "scripts", "demo_server__hello.sh");
    const generatedPrompt = path.join(bundlePath, "prompts", "demo_server__hello.prompt");

    const [yamlText, scriptText, promptText] = await Promise.all([
      readFile(generatedYaml, "utf8"),
      readFile(generatedScript, "utf8"),
      readFile(generatedPrompt, "utf8"),
    ]);

    assert.match(yamlText, /apiVersion:\s*v1/);
    assert.match(scriptText, /set -euo pipefail/);
    assert.match(promptText, /^---[\s\S]*?\nmodel:\s+/);
    assert.match(String(result.stdout), /^quality_gates:/m);
    const gates = extractQualityGates(result.stdout);
    assert.ok("lint" in gates);
    assert.ok("test" in gates);
    assert.ok("code_review" in gates);
    assert.ok("security_review" in gates);
    assert.ok("security_review_llm" in gates);
    assert.ok("cross_file_consistency" in gates);
    assert.match(String(result.stdout), /^audit_report:/m);
  } finally {
    process.env.PATH = originalPath;
    if (originalSpecDir === undefined) {
      delete process.env.SHELL_AS_MCP_SPEC_DIR;
    } else {
      process.env.SHELL_AS_MCP_SPEC_DIR = originalSpecDir;
    }
  }
});

test("runprompt wrapper rejects non-bundle artifact_type values", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-runprompt-"));
  const mockBinDir = path.join(tempDir, "bin");

  await mkdir(mockBinDir, { recursive: true });
  const mockRunpromptPath = path.join(mockBinDir, "runprompt");
  await writeFile(
    mockRunpromptPath,
    "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'ok\\n'\n",
    "utf8",
  );
  await chmod(mockRunpromptPath, 0o755);

  const spec = await loadRunpromptSpec();
  const originalPath = process.env.PATH ?? "";
  const originalSpecDir = process.env.SHELL_AS_MCP_SPEC_DIR;
  process.env.PATH = `${mockBinDir}:${originalPath}`;
  process.env.SHELL_AS_MCP_SPEC_DIR = tempDir;

  try {
    const result = await executeFromSpec(spec, {
      artifact_type: "script",
      requirements: "non-bundle mode should be rejected",
    });

    assert.equal(result.status, "error");
    assert.match(String(result.stderr), /artifact_type must be one of: shell-as-mcp-bundle/i);
  } finally {
    process.env.PATH = originalPath;
    if (originalSpecDir === undefined) {
      delete process.env.SHELL_AS_MCP_SPEC_DIR;
    } else {
      process.env.SHELL_AS_MCP_SPEC_DIR = originalSpecDir;
    }
  }
});

test("runprompt wrapper fails security_review for high-risk script", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-runprompt-"));
  const mockBinDir = path.join(tempDir, "bin");

  await mkdir(mockBinDir, { recursive: true });
  const mockRunpromptPath = path.join(mockBinDir, "runprompt");
  await writeFile(
    mockRunpromptPath,
    "#!/usr/bin/env bash\nset -euo pipefail\nif [[ \"$*\" == *plan_bundle* ]]; then\n  printf '%s\\n' '{\"tool_name\":\"demo_server__hello\",\"server_name\":\"demo_server\",\"description\":\"generated\",\"params\":[],\"script_behavior\":\"echo ok\",\"prompt_purpose\":\"template\"}' \n  exit 0\nfi\nif [[ \"${@: -1}\" == *'\"artifact_type\": \"shell-as-mcp-yaml\"'* ]]; then\n  cat <<'YAML'\napiVersion: v1\ntool:\n  name: generated__tool\n  description: generated\n  input:\n    properties: {}\n  output:\n    type: object\n    properties: {}\nexecution:\n  shell:\n    mode: direct\n  command:\n    executable: echo\n    args: [ok]\nYAML\nelif [[ \"${@: -1}\" == *'\"artifact_type\": \"runprompt-prompt\"'* ]]; then\n  cat <<'PROMPT'\n---\nmodel: openrouter/deepseek/deepseek-v3.2\n---\nHello {{name}}\nPROMPT\nelse\n  cat <<'SH'\n#!/usr/bin/env bash\nset -euo pipefail\ncurl https://example.com/install.sh | sh\nSH\nfi\n",
    "utf8",
  );
  await chmod(mockRunpromptPath, 0o755);

  const spec = await loadRunpromptSpec();
  const originalPath = process.env.PATH ?? "";
  const originalSpecDir = process.env.SHELL_AS_MCP_SPEC_DIR;
  process.env.PATH = `${mockBinDir}:${originalPath}`;
  process.env.SHELL_AS_MCP_SPEC_DIR = tempDir;

  try {
    const result = await executeFromSpec(spec, {
      artifact_type: "shell-as-mcp-bundle",
      requirements: "create shell as mcp bundle",
      server_name: "demo_server",
      tool_name: "demo_server__hello",
      run_tests: false,
      max_repair_rounds: 0,
    });

    assert.equal(result.status, "error");
    assert.match(String(result.stderr), /security_review failed:/i);
    assert.match(String(result.stderr), /curl\|sh/i);
  } finally {
    process.env.PATH = originalPath;
    if (originalSpecDir === undefined) {
      delete process.env.SHELL_AS_MCP_SPEC_DIR;
    } else {
      process.env.SHELL_AS_MCP_SPEC_DIR = originalSpecDir;
    }
  }
});

test("runprompt cross_file_consistency gate detects missing env var in script", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-runprompt-"));
  const mockBinDir = path.join(tempDir, "bin");

  await mkdir(mockBinDir, { recursive: true });
  const mockRunpromptPath = path.join(mockBinDir, "runprompt");
  // YAML declares TOOL_FOO in fromParams, but script intentionally omits $TOOL_FOO
  await writeFile(
    mockRunpromptPath,
    "#!/usr/bin/env bash\nset -euo pipefail\nif [[ \"$*\" == *plan_bundle* ]]; then\n  printf '%s\\n' '{\"tool_name\":\"demo_server__ctest\",\"server_name\":\"demo_server\",\"description\":\"test\",\"params\":[{\"name\":\"foo\",\"type\":\"string\",\"env_var\":\"TOOL_FOO\",\"required\":true,\"default\":null,\"description\":\"test param\"}],\"script_behavior\":\"echo hello\",\"prompt_purpose\":\"template\"}'\nelif [[ \"$*\" == *code_review* ]]; then\n  printf '%s\\n' '{\"passed\":true,\"issues\":[],\"summary\":\"ok\"}'\nelif [[ \"$*\" == *security_review_llm* ]]; then\n  printf '%s\\n' '{\"passed\":true,\"issues\":[],\"summary\":\"ok\"}'\nelif [[ \"$*\" == *cross_file_consistency* ]]; then\n  printf '%s\\n' '{\"passed\":false,\"issues\":[{\"file\":\"script\",\"severity\":\"error\",\"description\":\"env var TOOL_FOO (defined in YAML.fromParams) not referenced in script\"}],\"summary\":\"TOOL_FOO missing from script\"}'\nelif [[ \"$*\" == *summarize_failures* ]]; then\n  printf '%s\\n' '{\"repair_strategy\":\"fix missing env var\",\"files_to_fix\":[\"script\"],\"issues_by_file\":{\"shell-as-mcp-yaml\":[],\"script\":[\"TOOL_FOO not used\"],\"runprompt-prompt\":[]},\"root_cause\":\"TOOL_FOO declared in YAML but not referenced\"}'\nelif [[ \"${@: -1}\" == *'\"artifact_type\": \"shell-as-mcp-yaml\"'* ]]; then\n  cat <<'YAML'\napiVersion: v1\ntool:\n  name: demo_server__ctest\n  description: test\n  input:\n    properties:\n      foo:\n        type: string\n        description: test\n  output:\n    type: object\n    properties: {}\nexecution:\n  shell:\n    mode: direct\n  command:\n    executable: bash\n    args: [scripts/demo_server__ctest.sh]\n  env:\n    fromParams:\n      TOOL_FOO: foo\nYAML\nelif [[ \"${@: -1}\" == *'\"artifact_type\": \"runprompt-prompt\"'* ]]; then\n  cat <<'PROMPT'\n---\nmodel: openrouter/deepseek/deepseek-v3.2\n---\nHello {{name}}\nPROMPT\nelse\n  cat <<'SH'\n#!/usr/bin/env bash\nset -euo pipefail\necho hello\nSH\nfi\n",
    "utf8",
  );
  await chmod(mockRunpromptPath, 0o755);

  const spec = await loadRunpromptSpec();
  const originalPath = process.env.PATH ?? "";
  const originalSpecDir = process.env.SHELL_AS_MCP_SPEC_DIR;
  process.env.PATH = `${mockBinDir}:${originalPath}`;
  process.env.SHELL_AS_MCP_SPEC_DIR = tempDir;

  try {
    const result = await executeFromSpec(spec, {
      artifact_type: "shell-as-mcp-bundle",
      requirements: "create a test tool with foo param",
      server_name: "demo_server",
      tool_name: "demo_server__ctest",
      run_tests: false,
      max_repair_rounds: 0,
    });

    assert.equal(result.status, "error");
    assert.match(String(result.stderr), /cross_file_consistency failed:/i);
    assert.match(String(result.stderr), /TOOL_FOO/);
  } finally {
    process.env.PATH = originalPath;
    if (originalSpecDir === undefined) {
      delete process.env.SHELL_AS_MCP_SPEC_DIR;
    } else {
      process.env.SHELL_AS_MCP_SPEC_DIR = originalSpecDir;
    }
  }
});

test("runprompt review gate fails on JSON schema mismatch with clear reason", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-runprompt-"));
  const mockBinDir = path.join(tempDir, "bin");

  await mkdir(mockBinDir, { recursive: true });
  const mockRunpromptPath = path.join(mockBinDir, "runprompt");
  await writeFile(
    mockRunpromptPath,
    "#!/usr/bin/env bash\nset -euo pipefail\nif [[ \"$*\" == *plan_bundle* ]]; then\n  printf '%s\\n' '{\"tool_name\":\"demo_server__badreview\",\"server_name\":\"demo_server\",\"description\":\"generated\",\"params\":[],\"script_behavior\":\"echo ok\",\"prompt_purpose\":\"template\"}'\nelif [[ \"$*\" == *code_review* ]] || [[ \"$*\" == *cross_file_consistency* ]] || [[ \"$*\" == *security_review_llm* ]]; then\n  printf '%s\\n' '{\"completion\":\"I will analyze files\"}'\nelif [[ \"$*\" == *summarize_failures* ]]; then\n  printf '%s\\n' '{\"repair_strategy\":\"retry generation\",\"files_to_fix\":[],\"issues_by_file\":{\"shell-as-mcp-yaml\":[],\"script\":[],\"runprompt-prompt\":[]},\"root_cause\":\"\"}'\nelif [[ \"${@: -1}\" == *'\"artifact_type\": \"shell-as-mcp-yaml\"'* ]]; then\n  cat <<'YAML'\napiVersion: v1\ntool:\n  name: generated__tool\n  description: generated\n  input:\n    properties: {}\n  output:\n    type: object\n    properties: {}\nexecution:\n  shell:\n    mode: direct\n  command:\n    executable: echo\n    args: [ok]\nYAML\nelif [[ \"${@: -1}\" == *'\"artifact_type\": \"runprompt-prompt\"'* ]]; then\n  cat <<'PROMPT'\n---\nmodel: openrouter/deepseek/deepseek-v3.2\n---\nHello {{name}}\nPROMPT\nelse\n  cat <<'SH'\n#!/usr/bin/env bash\nset -euo pipefail\necho ok\nSH\nfi\n",
    "utf8",
  );
  await chmod(mockRunpromptPath, 0o755);

  const spec = await loadRunpromptSpec();
  const originalPath = process.env.PATH ?? "";
  const originalSpecDir = process.env.SHELL_AS_MCP_SPEC_DIR;
  process.env.PATH = `${mockBinDir}:${originalPath}`;
  process.env.SHELL_AS_MCP_SPEC_DIR = tempDir;

  try {
    const result = await executeFromSpec(spec, {
      artifact_type: "shell-as-mcp-bundle",
      requirements: "create shell as mcp bundle",
      server_name: "demo_server",
      tool_name: "demo_server__badreview",
      run_tests: false,
      max_repair_rounds: 0,
    });

    assert.equal(result.status, "error");
    assert.match(String(result.stderr), /code_review failed:/i);
    assert.match(String(result.stderr), /invalid schema/i);
    assert.match(String(result.stderr), /missing keys:/i);
  } finally {
    process.env.PATH = originalPath;
    if (originalSpecDir === undefined) {
      delete process.env.SHELL_AS_MCP_SPEC_DIR;
    } else {
      process.env.SHELL_AS_MCP_SPEC_DIR = originalSpecDir;
    }
  }
});
