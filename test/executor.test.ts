import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { executeFromSpec, sanitizeOutputText } from "../src/executor.js";
import type { ShellToolSpec } from "../src/types.js";

test("sanitizeOutputText escapes non-printable control chars", () => {
  assert.equal(sanitizeOutputText("a\u0000b\u0007c"), "a\\x00b\\x07c");
});

test("sanitizeOutputText preserves tabs and newlines", () => {
  assert.equal(sanitizeOutputText("a\tb\nc\r\n"), "a\tb\nc\r\n");
});

test("executeFromSpec returns text-safe stdout for binary-like output", async () => {
  const spec: ShellToolSpec = {
    apiVersion: "v1",
    tool: {
      name: "binary_safe",
      description: "/** binary-safe */",
      input: { properties: {} },
      output: {
        type: "object",
        properties: {},
      },
    },
    execution: {
      command: {
        executable: "node",
        args: ["-e", "process.stdout.write('A\\x00B')"],
      },
      timeoutMs: 5_000,
    },
  };

  const result = await executeFromSpec(spec, {});

  assert.equal(result.status, "success");
  assert.equal(result.stdout, "A\\x00B");
});

test("executeFromSpec supports script execution with interpreter", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-script-"));
  const scriptPath = path.join(dir, "echo.js");
  await writeFile(
    scriptPath,
    "const value = process.argv[2] ?? ''; process.stdout.write(`script:${value}`);",
    "utf8",
  );

  const spec: ShellToolSpec = {
    apiVersion: "v1",
    tool: {
      name: "script_echo",
      description: "/** script echo */",
      input: {
        properties: {
          value: { type: "string" },
        },
        required: ["value"],
      },
      output: {
        type: "object",
        properties: {},
      },
    },
    execution: {
      script: {
        path: "./echo.js",
        interpreter: "node",
        args: ["{{value}}"],
      },
      timeoutMs: 5_000,
    },
    __meta: {
      specDir: dir,
    },
  };

  const result = await executeFromSpec(spec, { value: "ok" });
  assert.equal(result.status, "success");
  assert.equal(result.stdout, "script:ok");
});

test("executeFromSpec propagates parent environment variables to script", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-script-env-"));
  const scriptPath = path.join(dir, "env.js");
  await writeFile(scriptPath, "process.stdout.write(process.env.TEST_INHERITED_VAR ?? '');", "utf8");

  const spec: ShellToolSpec = {
    apiVersion: "v1",
    tool: {
      name: "script_env",
      description: "/** script env */",
      input: { properties: {} },
      output: {
        type: "object",
        properties: {},
      },
    },
    execution: {
      script: {
        path: "./env.js",
        interpreter: "node",
      },
      timeoutMs: 5_000,
    },
    __meta: {
      specDir: dir,
    },
  };

  const original = process.env.TEST_INHERITED_VAR;
  process.env.TEST_INHERITED_VAR = "inherited-ok";
  try {
    const result = await executeFromSpec(spec, {});
    assert.equal(result.status, "success");
    assert.equal(result.stdout, "inherited-ok");
  } finally {
    if (original === undefined) {
      delete process.env.TEST_INHERITED_VAR;
    } else {
      process.env.TEST_INHERITED_VAR = original;
    }
  }
});
