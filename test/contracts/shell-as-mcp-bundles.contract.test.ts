import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { normalizeTSDocDescription } from "../../src/tsdoc.js";
import {
  getBundleDirs,
  getParamNames,
  getTestedTargets,
  loadBundleSpecs,
  resolveBundleRelativePath,
} from "./shell-as-mcp-contract-test-helpers.js";

test("bundle directories satisfy minimal shell_as_mcp contract", async () => {
  const bundleDirs = await getBundleDirs();
  assert.ok(bundleDirs.length > 0, "expected at least one bundle directory");

  for (const bundleDir of bundleDirs) {
    const specDir = path.join(bundleDir, "spec_yaml");
    const scriptsDir = path.join(bundleDir, "scripts");
    const specs = await loadBundleSpecs(bundleDir);

    assert.ok(specs.length > 0, `expected at least one YAML spec in ${specDir}`);
    await readdir(specDir);
    await readdir(scriptsDir);
  }
});

test("bundle specs resolve to complete cross-file assets", async () => {
  const bundleDirs = await getBundleDirs();

  for (const bundleDir of bundleDirs) {
    const scriptsDir = path.join(bundleDir, "scripts");
    const scriptNames = await readdir(scriptsDir);
    const specs = await loadBundleSpecs(bundleDir);
    const healthzSpecs = specs.filter(({ spec }) => spec.tool.name.endsWith("__healthz"));

    assert.ok(healthzSpecs.length >= 1, `expected a __healthz spec in ${bundleDir}`);

    for (const { fileName, spec } of specs) {
      assert.equal(spec.apiVersion, "v1", `${fileName} must declare apiVersion v1`);
      assert.equal(fileName, `${spec.tool.name}.yaml`, `${fileName} should match tool.name`);
      assert.ok(spec.tool.description, `${fileName} must have tool.description`);
      normalizeTSDocDescription(spec.tool.description);

      const inputProperties = Object.keys(spec.tool.input.properties ?? {});
      if (inputProperties.length > 0) {
        const paramNames = getParamNames(spec.tool.description);
        for (const propertyName of inputProperties) {
          assert.ok(
            paramNames.has(propertyName),
            `${fileName} is missing @param documentation for ${propertyName}`,
          );
        }
      }

      const scriptPath = spec.execution.script?.path;
      if (scriptPath) {
        const resolvedScriptPath = resolveBundleRelativePath(bundleDir, scriptPath);
        await readFile(resolvedScriptPath, "utf8");
      }
    }

    for (const { fileName, spec } of healthzSpecs) {
      assert.deepEqual(
        spec.tool.input.properties,
        {},
        `${fileName} healthz tool input.properties must be empty`,
      );
      assert.deepEqual(
        spec.tool.input.required ?? [],
        [],
        `${fileName} healthz tool required must be empty`,
      );
      assert.ok(
        spec.execution.script?.path,
        `${fileName} healthz spec must reference a script`,
      );
    }

    const testedTargets = getTestedTargets(specs);
    if (testedTargets.length === 0) {
      continue;
    }

    const genericSmokeName = scriptNames.find((name) => name.endsWith("__smoke_test.sh"));
    assert.ok(
      genericSmokeName,
      `expected a generic smoke test anchor in ${scriptsDir} for tested targets`,
    );

    const smokePrefix = genericSmokeName?.replace(/__smoke_test\.sh$/, "") ?? "";
    for (const target of testedTargets) {
      const expectedName = `${smokePrefix}__smoke_test__${target.kernel}_${target.arch}.sh`;
      assert.ok(
        scriptNames.includes(expectedName),
        `missing per-target smoke script ${expectedName} in ${scriptsDir}`,
      );
    }
  }
});
