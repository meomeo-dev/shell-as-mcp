import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { parse } from "yaml";
import { normalizeTSDocDescription } from "../../src/tsdoc.js";
import type { CompatibilityTarget, ShellToolSpec } from "../../src/types.js";

export const repoRoot = process.cwd();
export const defsRoot = path.join(repoRoot, "shell_as_mcp_defs");

export type BundleSpecRecord = {
  fileName: string;
  spec: ShellToolSpec;
};

export async function getBundleDirs(): Promise<string[]> {
  const entries = await readdir(defsRoot, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
    .map((entry) => path.join(defsRoot, entry.name))
    .sort();
}

export async function loadBundleSpecs(bundleDir: string): Promise<BundleSpecRecord[]> {
  const specDir = path.join(bundleDir, "spec_yaml");
  const fileNames = (await readdir(specDir))
    .filter((fileName) => fileName.endsWith(".yaml") || fileName.endsWith(".yml"))
    .sort();

  const records: BundleSpecRecord[] = [];
  for (const fileName of fileNames) {
    const content = await readFile(path.join(specDir, fileName), "utf8");
    records.push({
      fileName,
      spec: parse(content) as ShellToolSpec,
    });
  }
  return records;
}

export function resolveBundleRelativePath(bundleDir: string, relativePath: string): string {
  const resolvedPath = path.resolve(bundleDir, relativePath);
  const normalizedBundleDir = path.resolve(bundleDir);
  if (
    resolvedPath !== normalizedBundleDir &&
    !resolvedPath.startsWith(`${normalizedBundleDir}${path.sep}`)
  ) {
    throw new Error(`resolved path escapes bundle root: ${relativePath}`);
  }
  return resolvedPath;
}

export function getParamNames(description: string): Set<string> {
  const normalized = normalizeTSDocDescription(description);
  const paramNames = new Set<string>();
  for (const line of normalized.split("\n")) {
    const match = line.match(/^@param\s+([A-Za-z0-9_]+)\b/);
    if (match) {
      paramNames.add(match[1]);
    }
  }
  return paramNames;
}

export function getTestedTargets(records: BundleSpecRecord[]): CompatibilityTarget[] {
  return records.flatMap(({ spec }) =>
    (spec.execution.compatibility?.targets ?? []).filter(
      (target) => target.support === "tested",
    ),
  );
}
