import assert from "node:assert/strict";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { buildExecutionPlan } from "../src/executor.js";
import { loadSpecs, loadSpecsWithOptions } from "../src/spec-loader.js";
import { normalizeTSDocDescription } from "../src/tsdoc.js";
import type { ShellToolSpec } from "../src/types.js";

const specDir = path.resolve(process.cwd(), "shell_as_mcp_defs");

test("loads bundled tool specs", async () => {
  const specs = await loadSpecs(specDir);
  const names = new Set(specs.map((spec) => spec.tool.name));
  assert.ok(names.has("ffmpeg__process_video_for_llm"));
  assert.ok(names.has("ffmpeg__process_audio_for_stt"));
  assert.ok(names.has("ffmpeg__extract_frames_for_vision"));
  assert.ok(names.has("ffmpeg__create_video_summary"));
  assert.ok(names.has("runprompt__generate_artifact"));
});

test("maps params into command args and env vars", () => {
  const originalLegacy = process.env.TEST_LEGACY_ENV;
  const originalPreferred = process.env.TEST_PREFERRED_ENV;
  process.env.TEST_LEGACY_ENV = "legacy-value";
  process.env.TEST_PREFERRED_ENV = "preferred-value";

  const spec: ShellToolSpec = {
    apiVersion: "v1",
    tool: {
      name: "demo__echo",
      description: "/** demo */",
      input: {
        properties: {
          value: { type: "string" },
        },
        required: ["value"],
      },
      output: { type: "object", properties: {} },
    },
    execution: {
      shell: { mode: "direct" },
      env: {
        static: { STATIC_ENV: "ok" },
        fromParams: { DYNAMIC_ENV: "value" },
        fromRuntime: {
          MAPPED_ENV: ["TEST_PREFERRED_ENV", "TEST_LEGACY_ENV"],
        },
      },
      command: {
        executable: "echo",
        args: ["{{value}}"],
      },
    },
  };

  try {
    const plan = buildExecutionPlan(spec, { value: "hello" });
    assert.equal(plan.executable, "echo");
    assert.deepEqual(plan.launchArgs, ["hello"]);
    assert.equal(plan.env.STATIC_ENV, "ok");
    assert.equal(plan.env.DYNAMIC_ENV, "hello");
    assert.equal(plan.env.MAPPED_ENV, "preferred-value");
    assert.equal(plan.commandDisplay, "echo hello");
  } finally {
    if (originalLegacy === undefined) {
      delete process.env.TEST_LEGACY_ENV;
    } else {
      process.env.TEST_LEGACY_ENV = originalLegacy;
    }
    if (originalPreferred === undefined) {
      delete process.env.TEST_PREFERRED_ENV;
    } else {
      process.env.TEST_PREFERRED_ENV = originalPreferred;
    }
  }
});

test("ytdlp output_dir fallback applies and fromParams overrides runtime fallback", () => {
  const originalGroup = process.env.YTDLP_OUTPUT_DIR;
  const originalGlobal = process.env.SHELL_AS_MCP_OUTPUT_DIR;
  process.env.YTDLP_OUTPUT_DIR = "/tmp/group-output";
  process.env.SHELL_AS_MCP_OUTPUT_DIR = "/tmp/global-output";

  const spec: ShellToolSpec = {
    apiVersion: "v1",
    tool: {
      name: "demo__output_dir",
      description: "/** demo */",
      input: {
        properties: {
          output_dir: { type: "string" },
        },
      },
      output: { type: "object", properties: {} },
    },
    execution: {
      shell: { mode: "direct" },
      env: {
        fromRuntime: {
          TOOL_OUTPUT_DIR: ["YTDLP_OUTPUT_DIR", "SHELL_AS_MCP_OUTPUT_DIR"],
        },
        fromParams: {
          TOOL_OUTPUT_DIR: "output_dir",
        },
      },
      command: {
        executable: "echo",
      },
    },
  };

  try {
    const fallbackPlan = buildExecutionPlan(spec, {});
    assert.equal(fallbackPlan.env.TOOL_OUTPUT_DIR, "/tmp/group-output");

    const plan = buildExecutionPlan(spec, { output_dir: "/tmp/param-output" });
    assert.equal(plan.env.TOOL_OUTPUT_DIR, "/tmp/param-output");
  } finally {
    if (originalGroup === undefined) {
      delete process.env.YTDLP_OUTPUT_DIR;
    } else {
      process.env.YTDLP_OUTPUT_DIR = originalGroup;
    }
    if (originalGlobal === undefined) {
      delete process.env.SHELL_AS_MCP_OUTPUT_DIR;
    } else {
      process.env.SHELL_AS_MCP_OUTPUT_DIR = originalGlobal;
    }
  }
});

test("bundled ytdlp download specs expose layered output directory defaults", async () => {
  const specs = await loadSpecs(specDir);
  const expectedTools = new Set([
    "ytdlp__download_video",
    "ytdlp__download_audio",
    "ytdlp__download_video_subtitles",
  ]);

  const matchedSpecs = specs.filter((spec) => expectedTools.has(spec.tool.name));
  assert.equal(matchedSpecs.length, 3);

  for (const spec of matchedSpecs) {
    assert.equal(spec.tool.input.properties.output_dir?.type, "string");
    assert.deepEqual(spec.execution.env?.fromRuntime?.TOOL_OUTPUT_DIR, [
      "YTDLP_OUTPUT_DIR",
      "SHELL_AS_MCP_OUTPUT_DIR",
    ]);
    assert.equal(spec.execution.env?.fromParams?.TOOL_OUTPUT_DIR, "output_dir");
  }
});

test("runtime fallback uses global ffmpeg output dir when group env is absent", () => {
  const originalGroup = process.env.FFMPEG_OUTPUT_DIR;
  const originalGlobal = process.env.SHELL_AS_MCP_OUTPUT_DIR;
  delete process.env.FFMPEG_OUTPUT_DIR;
  process.env.SHELL_AS_MCP_OUTPUT_DIR = "/tmp/ffmpeg-global-output";

  const spec: ShellToolSpec = {
    apiVersion: "v1",
    tool: {
      name: "demo__ffmpeg_extract",
      description: "/** demo */",
      input: {
        properties: {
          input_path: { type: "string" },
          output_dir: { type: "string" },
        },
        required: ["input_path"],
      },
      output: { type: "object", properties: {} },
    },
    execution: {
      shell: { mode: "direct" },
      env: {
        fromRuntime: {
          TOOL_OUTPUT_DIR: ["FFMPEG_OUTPUT_DIR", "SHELL_AS_MCP_OUTPUT_DIR"],
        },
        fromParams: {
          TOOL_OUTPUT_DIR: "output_dir",
          INPUT_PATH: "input_path",
        },
      },
      command: {
        executable: "echo",
      },
    },
  };

  try {
    const plan = buildExecutionPlan(spec, { input_path: "/tmp/input.mp4" });
    assert.equal(plan.env.TOOL_OUTPUT_DIR, "/tmp/ffmpeg-global-output");
  } finally {
    if (originalGroup === undefined) {
      delete process.env.FFMPEG_OUTPUT_DIR;
    } else {
      process.env.FFMPEG_OUTPUT_DIR = originalGroup;
    }
    if (originalGlobal === undefined) {
      delete process.env.SHELL_AS_MCP_OUTPUT_DIR;
    } else {
      process.env.SHELL_AS_MCP_OUTPUT_DIR = originalGlobal;
    }
  }
});

test("ffmpeg output_dir fallback applies and fromParams overrides runtime fallback", () => {
  const originalGroup = process.env.FFMPEG_OUTPUT_DIR;
  const originalGlobal = process.env.SHELL_AS_MCP_OUTPUT_DIR;
  process.env.FFMPEG_OUTPUT_DIR = "/tmp/ffmpeg-group-output";
  process.env.SHELL_AS_MCP_OUTPUT_DIR = "/tmp/ffmpeg-global-output";

  const spec: ShellToolSpec = {
    apiVersion: "v1",
    tool: {
      name: "demo__ffmpeg_split",
      description: "/** demo */",
      input: {
        properties: {
          output_dir: { type: "string" },
        },
      },
      output: { type: "object", properties: {} },
    },
    execution: {
      shell: { mode: "direct" },
      env: {
        fromRuntime: {
          TOOL_OUTPUT_DIR: ["FFMPEG_OUTPUT_DIR", "SHELL_AS_MCP_OUTPUT_DIR"],
        },
        fromParams: {
          TOOL_OUTPUT_DIR: "output_dir",
        },
      },
      command: {
        executable: "echo",
      },
    },
  };

  try {
    const fallbackPlan = buildExecutionPlan(spec, {});
    assert.equal(fallbackPlan.env.TOOL_OUTPUT_DIR, "/tmp/ffmpeg-group-output");

    const overridePlan = buildExecutionPlan(spec, { output_dir: "/tmp/ffmpeg-param-output" });
    assert.equal(overridePlan.env.TOOL_OUTPUT_DIR, "/tmp/ffmpeg-param-output");
  } finally {
    if (originalGroup === undefined) {
      delete process.env.FFMPEG_OUTPUT_DIR;
    } else {
      process.env.FFMPEG_OUTPUT_DIR = originalGroup;
    }
    if (originalGlobal === undefined) {
      delete process.env.SHELL_AS_MCP_OUTPUT_DIR;
    } else {
      process.env.SHELL_AS_MCP_OUTPUT_DIR = originalGlobal;
    }
  }
});

test("bundled ffmpeg extract spec exposes layered output directory defaults", async () => {
  const specs = await loadSpecs(specDir);
  const spec = specs.find((item) => item.tool.name === "ffmpeg__extract_frames_for_vision");

  assert.ok(spec);
  assert.equal(spec.tool.input.properties.output_dir?.type, "string");
  assert.deepEqual(spec.tool.input.required, ["input_path"]);
  assert.deepEqual(spec.execution.env?.fromRuntime?.TOOL_OUTPUT_DIR, [
    "FFMPEG_OUTPUT_DIR",
    "SHELL_AS_MCP_OUTPUT_DIR",
  ]);
  assert.equal(spec.execution.env?.fromParams?.TOOL_OUTPUT_DIR, "output_dir");
});

test("bundled ffmpeg split spec exposes layered output directory defaults", async () => {
  const specs = await loadSpecs(specDir);
  const spec = specs.find((item) => item.tool.name === "ffmpeg__split_video");

  assert.ok(spec);
  assert.equal(spec.tool.input.properties.output_dir?.type, "string");
  assert.deepEqual(spec.execution.env?.fromRuntime?.TOOL_OUTPUT_DIR, [
    "FFMPEG_OUTPUT_DIR",
    "SHELL_AS_MCP_OUTPUT_DIR",
  ]);
  assert.equal(spec.execution.env?.fromParams?.TOOL_OUTPUT_DIR, "output_dir");
});

test("bundled ass specs expose layered output directory defaults", async () => {
  const specs = await loadSpecs(specDir);
  const expectedTools = new Set(["ass__create_template", "ass__smoke_test"]);
  const matchedSpecs = specs.filter((spec) => expectedTools.has(spec.tool.name));

  assert.equal(matchedSpecs.length, 2);

  for (const spec of matchedSpecs) {
    assert.equal(spec.tool.input.properties.output_dir?.type, "string");
    assert.deepEqual(spec.execution.env?.fromRuntime?.TOOL_OUTPUT_DIR, [
      "ASS_OUTPUT_DIR",
      "SHELL_AS_MCP_OUTPUT_DIR",
    ]);
    assert.equal(spec.execution.env?.fromParams?.TOOL_OUTPUT_DIR, "output_dir");
  }
});

test("maps params into script args with relative path and interpreter", () => {
  const spec: ShellToolSpec = {
    apiVersion: "v1",
    tool: {
      name: "demo__script",
      description: "/** demo */",
      input: {
        properties: {
          value: { type: "string" },
        },
        required: ["value"],
      },
      output: { type: "object", properties: {} },
    },
    execution: {
      script: {
        path: "./scripts/demo.sh",
        interpreter: "bash",
        args: ["{{value}}"],
      },
    },
    __meta: {
      specDir: "/tmp/specs",
    },
  };

  const plan = buildExecutionPlan(spec, { value: "hello world" });
  assert.equal(plan.executable, "bash");
  assert.deepEqual(plan.launchArgs, ["/tmp/specs/scripts/demo.sh", "hello world"]);
  assert.equal(plan.commandDisplay, "bash /tmp/specs/scripts/demo.sh 'hello world'");
});

test("rejects yaml specs that still use docstring", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-"));
  await mkdir(path.join(dir, "testserver", "spec_yaml"), { recursive: true });
  await writeFile(
    path.join(dir, "testserver", "spec_yaml", "invalid.yaml"),
    `apiVersion: v1
tool:
  name: invalid_tool
  description: |
    /**
     * Valid TSDoc description
     */
  docstring: should_not_exist
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  command:
    executable: echo
`,
    "utf8",
  );

  await assert.rejects(loadSpecs(dir), /docstring is not supported/);
});

test("rejects yaml specs when description is not TSDoc", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-"));
  await mkdir(path.join(dir, "testserver", "spec_yaml"), { recursive: true });
  await writeFile(
    path.join(dir, "testserver", "spec_yaml", "invalid-tsdoc.yaml"),
    `apiVersion: v1
tool:
  name: invalid_tsdoc
  description: plain text description
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  command:
    executable: echo
`,
    "utf8",
  );

  await assert.rejects(loadSpecs(dir), /TSDoc block comment/);
});

test("rejects yaml specs without command or script", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-"));
  await mkdir(path.join(dir, "testserver", "spec_yaml"), { recursive: true });
  await writeFile(
    path.join(dir, "testserver", "spec_yaml", "invalid-execution.yaml"),
    `apiVersion: v1
tool:
  name: invalid_execution
  description: |
    /**
     * Valid TSDoc description
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  timeoutMs: 1000
`,
    "utf8",
  );

  await assert.rejects(loadSpecs(dir), /execution.command or execution.script is required/);
});

test("rejects yaml specs with both command and script", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-"));
  await mkdir(path.join(dir, "testserver", "spec_yaml"), { recursive: true });
  await writeFile(
    path.join(dir, "testserver", "spec_yaml", "invalid-both.yaml"),
    `apiVersion: v1
tool:
  name: invalid_both
  description: |
    /**
     * Valid TSDoc description
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  command:
    executable: echo
  script:
    path: ./demo.sh
`,
    "utf8",
  );

  await assert.rejects(loadSpecs(dir), /execution.command and execution.script cannot both be set/);
});

test("rejects yaml specs when execution.env.fromRuntime values are invalid", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-"));
  await mkdir(path.join(dir, "testserver", "spec_yaml"), { recursive: true });
  await writeFile(
    path.join(dir, "testserver", "spec_yaml", "invalid-env-from-runtime.yaml"),
    `apiVersion: v1
tool:
  name: invalid_env_from_runtime
  description: |
    /**
     * Valid TSDoc description
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  env:
    fromRuntime:
      BAD_MAP:
        invalid: object
  command:
    executable: echo
`,
    "utf8",
  );

  await assert.rejects(loadSpecs(dir), /execution\.env\.fromRuntime\.BAD_MAP must be a non-empty string or array of non-empty strings/);
});

test("accepts yaml specs with compatibility targets", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-"));
  await mkdir(path.join(dir, "testserver", "spec_yaml"), { recursive: true });
  await writeFile(
    path.join(dir, "testserver", "spec_yaml", "valid-compatibility.yaml"),
    `apiVersion: v1
tool:
  name: valid_compatibility
  description: |
    /**
     * Valid compatibility metadata.
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  compatibility:
    targets:
      - os: macos
        kernel: darwin
        arch: arm64
        support: tested
        notes: Apple Silicon developer machine
  command:
    executable: echo
`,
    "utf8",
  );

  const specs = await loadSpecsWithOptions(dir, {
    runtime: {
      os: "macos",
      kernel: "darwin",
      arch: "arm64",
    },
  });
  assert.equal(specs[0]?.execution.compatibility?.targets[0]?.kernel, "darwin");
  assert.equal(specs[0]?.execution.compatibility?.targets[0]?.support, "tested");
});

test("filters out specs with non-matching compatibility targets", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-"));
  await mkdir(path.join(dir, "testserver", "spec_yaml"), { recursive: true });

  await writeFile(
    path.join(dir, "testserver", "spec_yaml", "linux-only.yaml"),
    `apiVersion: v1
tool:
  name: linux_only_tool
  description: |
    /**
     * Linux only.
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  compatibility:
    targets:
      - os: linux
        kernel: linux
        arch: x86_64
        support: tested
  command:
    executable: echo
`,
    "utf8",
  );

  const specs = await loadSpecsWithOptions(dir, {
    runtime: {
      os: "macos",
      kernel: "darwin",
      arch: "arm64",
    },
  });

  assert.equal(specs.length, 0);
});

test("keeps specs without compatibility while filtering mismatched ones", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-"));
  await mkdir(path.join(dir, "testserver", "spec_yaml"), { recursive: true });

  await writeFile(
    path.join(dir, "testserver", "spec_yaml", "no-compat.yaml"),
    `apiVersion: v1
tool:
  name: no_compat_tool
  description: |
    /**
     * No compatibility metadata.
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  command:
    executable: echo
`,
    "utf8",
  );

  await writeFile(
    path.join(dir, "testserver", "spec_yaml", "darwin-only.yaml"),
    `apiVersion: v1
tool:
  name: darwin_only_tool
  description: |
    /**
     * Darwin only.
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  compatibility:
    targets:
      - os: macos
        kernel: darwin
        arch: arm64
        support: tested
  command:
    executable: echo
`,
    "utf8",
  );

  const specs = await loadSpecsWithOptions(dir, {
    runtime: {
      os: "linux",
      kernel: "linux",
      arch: "x86_64",
    },
  });
  const names = new Set(specs.map((spec) => spec.tool.name));
  assert.deepEqual(Array.from(names), ["no_compat_tool"]);
});

test("rejects yaml specs with compatibility targets missing kernel", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-"));
  await mkdir(path.join(dir, "testserver", "spec_yaml"), { recursive: true });
  await writeFile(
    path.join(dir, "testserver", "spec_yaml", "invalid-compatibility-kernel.yaml"),
    `apiVersion: v1
tool:
  name: invalid_compatibility_kernel
  description: |
    /**
     * Invalid compatibility metadata.
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  compatibility:
    targets:
      - os: macos
        arch: arm64
  command:
    executable: echo
`,
    "utf8",
  );

  await assert.rejects(loadSpecs(dir), /execution\.compatibility\.targets\[0\]\.kernel must be a non-empty string/);
});

test("rejects yaml specs with compatibility targets missing arch", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-"));
  await mkdir(path.join(dir, "testserver", "spec_yaml"), { recursive: true });
  await writeFile(
    path.join(dir, "testserver", "spec_yaml", "invalid-compatibility-arch.yaml"),
    `apiVersion: v1
tool:
  name: invalid_compatibility_arch
  description: |
    /**
     * Invalid compatibility metadata.
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  compatibility:
    targets:
      - os: macos
        kernel: darwin
  command:
    executable: echo
`,
    "utf8",
  );

  await assert.rejects(loadSpecs(dir), /execution\.compatibility\.targets\[0\]\.arch must be a non-empty string/);
});

test("rejects yaml specs with invalid compatibility support", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-"));
  await mkdir(path.join(dir, "testserver", "spec_yaml"), { recursive: true });
  await writeFile(
    path.join(dir, "testserver", "spec_yaml", "invalid-compatibility-support.yaml"),
    `apiVersion: v1
tool:
  name: invalid_compatibility_support
  description: |
    /**
     * Invalid compatibility metadata.
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  compatibility:
    targets:
      - os: linux
        kernel: linux
        arch: x86_64
        support: experimental
  command:
    executable: echo
`,
    "utf8",
  );

  await assert.rejects(loadSpecs(dir), /execution\.compatibility\.targets\[0\]\.support must be "tested" or "declared"/);
});

test("normalizes TSDoc description for MCP registration", () => {
  const description = normalizeTSDocDescription(`/**
 * Summary line.
 * @remarks Additional details.
 */`);

  assert.equal(description, "Summary line.\n@remarks Additional details.");
});

test("normalizes TSDoc with mixed indentation and preserves inner spacing", () => {
  const description = normalizeTSDocDescription(`/**
\t*   Summary with extra indentation.
  * @remarks  Two spaces before this sentence are preserved.
 * **Bold marker should remain in content.
 */`);

  assert.equal(
    description,
    "Summary with extra indentation.\n@remarks  Two spaces before this sentence are preserved.\n**Bold marker should remain in content.",
  );
});

test("rejects malformed TSDoc lines without leading *", () => {
  assert.throws(
    () =>
      normalizeTSDocDescription(`/**
 * valid line
 malformed line
 */`),
    /standard TSDoc line prefixes/,
  );
});

test("keeps intentional blank lines in TSDoc body", () => {
  const description = normalizeTSDocDescription(`/**
 * First line.
 *
 * Second line.
 */`);

  assert.equal(description, "First line.\n\nSecond line.");
});

test("loadSpecs merges specs from multiple directories", async () => {
  // Arrange: create two temp directories each with one unique tool
  const dir1 = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-multi-1-"));
  const dir2 = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-multi-2-"));

  await mkdir(path.join(dir1, "server1", "spec_yaml"), { recursive: true });
  await mkdir(path.join(dir2, "server2", "spec_yaml"), { recursive: true });

  const validSpec = (name: string) => `apiVersion: v1
tool:
  name: ${name}
  description: |
    /**
     * Tool ${name}
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  command:
    executable: echo
`;

  await writeFile(path.join(dir1, "server1", "spec_yaml", "tool1.yaml"), validSpec("tool__one"), "utf8");
  await writeFile(path.join(dir2, "server2", "spec_yaml", "tool2.yaml"), validSpec("tool__two"), "utf8");

  // Act
  const specs = await loadSpecs([dir1, dir2]);
  const names = new Set(specs.map((s) => s.tool.name));

  // Assert: both tools present
  assert.ok(names.has("tool__one"));
  assert.ok(names.has("tool__two"));
  assert.equal(specs.length, 2);
});

test("loadSpecs: later directory tools override earlier ones with same name", async () => {
  // Arrange: two directories both define the same tool name
  const dirBuiltin = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-builtin-"));
  const dirUser = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-user-"));

  await mkdir(path.join(dirBuiltin, "svc", "spec_yaml"), { recursive: true });
  await mkdir(path.join(dirUser, "svc", "spec_yaml"), { recursive: true });

  const builtinSpec = `apiVersion: v1
tool:
  name: shared__tool
  description: |
    /**
     * Built-in version
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  command:
    executable: builtin-echo
`;

  const userSpec = `apiVersion: v1
tool:
  name: shared__tool
  description: |
    /**
     * User version
     */
  input:
    properties: {}
  output:
    type: object
    properties: {}
execution:
  command:
    executable: user-echo
`;

  await writeFile(path.join(dirBuiltin, "svc", "spec_yaml", "shared.yaml"), builtinSpec, "utf8");
  await writeFile(path.join(dirUser, "svc", "spec_yaml", "shared.yaml"), userSpec, "utf8");

  // Act: user dir is second (later = higher priority)
  const specs = await loadSpecs([dirBuiltin, dirUser]);

  // Assert: only one tool with the user version
  assert.equal(specs.length, 1);
  assert.equal(specs[0].tool.name, "shared__tool");
  // User's executable wins
  assert.ok(
    "command" in specs[0].execution &&
    specs[0].execution.command !== undefined &&
    (specs[0].execution.command as { executable: string }).executable === "user-echo",
  );
});
