import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { defsRoot, loadBundleSpecs } from "./shell-as-mcp-contract-test-helpers.js";

test("iwencai bundle stays within the v1 read-only contract", async () => {
  const bundleDir = path.join(defsRoot, "iwencai");
  const specs = await loadBundleSpecs(bundleDir);
  const byName = new Map(specs.map(({ spec }) => [spec.tool.name, spec]));

  assert.deepEqual(
    new Set(byName.keys()),
    new Set([
      "iwencai__healthz",
      "iwencai__query2data_basic",
      "iwencai__search_basic",
      "iwencai__skillbook",
    ]),
  );

  const healthzSpec = byName.get("iwencai__healthz");
  assert.ok(healthzSpec, "missing iwencai__healthz spec");
  assert.deepEqual(healthzSpec.tool.input.properties, {});
  assert.deepEqual(healthzSpec.tool.input.required ?? [], []);

  const querySpec = byName.get("iwencai__query2data_basic");
  assert.ok(querySpec, "missing iwencai__query2data_basic spec");
  assert.deepEqual(Object.keys(querySpec.tool.input.properties).sort(), [
    "format",
    "limit",
    "page",
    "query",
  ]);
  assert.deepEqual(querySpec.tool.input.required ?? [], ["query"]);
  assert.equal(
    querySpec.execution.env?.fromRuntime?.TOOL_IWENCAI_API_KEY,
    "IWENCAI_API_KEY",
  );
  assert.ok(!("output" in querySpec.tool.input.properties));
  assert.ok(!("all_pages" in querySpec.tool.input.properties));

  const searchSpec = byName.get("iwencai__search_basic");
  assert.ok(searchSpec, "missing iwencai__search_basic spec");
  assert.deepEqual(Object.keys(searchSpec.tool.input.properties).sort(), [
    "channel",
    "format",
    "limit",
    "query",
  ]);
  assert.deepEqual(searchSpec.tool.input.required ?? [], ["query", "channel"]);
  assert.equal(
    searchSpec.execution.env?.fromRuntime?.TOOL_IWENCAI_API_KEY,
    "IWENCAI_API_KEY",
  );
  assert.ok(!("output" in searchSpec.tool.input.properties));

  const skillbookSpec = byName.get("iwencai__skillbook");
  assert.ok(skillbookSpec, "missing iwencai__skillbook spec");
  assert.deepEqual(Object.keys(skillbookSpec.tool.input.properties).sort(), [
    "format",
  ]);
  assert.deepEqual(skillbookSpec.tool.input.required ?? [], []);
  assert.equal(
    skillbookSpec.execution.env?.fromRuntime?.TOOL_IWENCAI_API_KEY,
    undefined,
  );
  assert.ok(!("output" in skillbookSpec.tool.input.properties));

  for (const specName of [
    "iwencai__query2data_basic",
    "iwencai__search_basic",
    "iwencai__skillbook",
  ]) {
    const spec = byName.get(specName);
    assert.ok(spec, `missing ${specName}`);
    const testedTargets = (spec.execution.compatibility?.targets ?? []).filter(
      (target) => target.support === "tested",
    );
    assert.ok(
      testedTargets.length >= 1,
      `${specName} should declare at least one tested target`,
    );
  }
});
