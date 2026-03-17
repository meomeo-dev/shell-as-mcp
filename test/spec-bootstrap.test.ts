import assert from "node:assert/strict";
import { access, mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { ensureSpecDirectoryReady } from "../src/spec-bootstrap.js";

test("ensureSpecDirectoryReady creates target directory if it does not exist", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-bootstrap-"));
  const targetSpecDir = path.join(tempDir, "custom-specs");

  await ensureSpecDirectoryReady(targetSpecDir);

  await assert.doesNotReject(access(targetSpecDir));
});

test("ensureSpecDirectoryReady is idempotent when called on an existing directory", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "shell-as-mcp-spec-bootstrap-"));

  await assert.doesNotReject(ensureSpecDirectoryReady(tempDir));
  await assert.doesNotReject(ensureSpecDirectoryReady(tempDir));
});
