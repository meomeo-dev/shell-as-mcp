import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { parse } from "yaml";
import { normalizeTSDocDescription } from "./tsdoc.js";
import type { ShellToolSpec } from "./types.js";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function assertSpec(spec: unknown, filePath: string): asserts spec is ShellToolSpec {
  if (!isRecord(spec)) {
    throw new Error(`Invalid spec in ${filePath}: root must be an object`);
  }

  if (spec.apiVersion !== "v1") {
    throw new Error(`Invalid spec in ${filePath}: apiVersion must be 'v1'`);
  }

  if (!isRecord(spec.tool)) {
    throw new Error(`Invalid spec in ${filePath}: missing tool block`);
  }

  if (typeof spec.tool.name !== "string" || spec.tool.name.length === 0) {
    throw new Error(`Invalid spec in ${filePath}: tool.name is required`);
  }

  if (typeof spec.tool.description !== "string" || spec.tool.description.length === 0) {
    throw new Error(`Invalid spec in ${filePath}: tool.description is required`);
  }
  try {
    normalizeTSDocDescription(spec.tool.description);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Invalid spec in ${filePath}: ${message}`);
  }

  if ("docstring" in spec.tool) {
    throw new Error(`Invalid spec in ${filePath}: use only tool.description (docstring is not supported)`);
  }

  if (!isRecord(spec.execution)) {
    throw new Error(`Invalid spec in ${filePath}: execution block is required`);
  }

  if ("env" in spec.execution && spec.execution.env !== undefined) {
    if (!isRecord(spec.execution.env)) {
      throw new Error(`Invalid spec in ${filePath}: execution.env must be an object`);
    }
    if ("static" in spec.execution.env && spec.execution.env.static !== undefined) {
      if (!isRecord(spec.execution.env.static)) {
        throw new Error(`Invalid spec in ${filePath}: execution.env.static must be an object`);
      }
      for (const [key, value] of Object.entries(spec.execution.env.static)) {
        if (typeof value !== "string") {
          throw new Error(`Invalid spec in ${filePath}: execution.env.static.${key} must be a string`);
        }
      }
    }
    if ("fromParams" in spec.execution.env && spec.execution.env.fromParams !== undefined) {
      if (!isRecord(spec.execution.env.fromParams)) {
        throw new Error(`Invalid spec in ${filePath}: execution.env.fromParams must be an object`);
      }
      for (const [key, value] of Object.entries(spec.execution.env.fromParams)) {
        if (typeof value !== "string") {
          throw new Error(`Invalid spec in ${filePath}: execution.env.fromParams.${key} must be a string`);
        }
      }
    }
    if ("fromRuntime" in spec.execution.env && spec.execution.env.fromRuntime !== undefined) {
      if (!isRecord(spec.execution.env.fromRuntime)) {
        throw new Error(`Invalid spec in ${filePath}: execution.env.fromRuntime must be an object`);
      }
      for (const [key, value] of Object.entries(spec.execution.env.fromRuntime)) {
        const validArray = Array.isArray(value) && value.every((entry) => typeof entry === "string" && entry.length > 0);
        if (!(typeof value === "string" && value.length > 0) && !validArray) {
          throw new Error(
            `Invalid spec in ${filePath}: execution.env.fromRuntime.${key} must be a non-empty string or array of non-empty strings`,
          );
        }
      }
    }
  }

  if ("compatibility" in spec.execution && spec.execution.compatibility !== undefined) {
    const compatibility = spec.execution.compatibility;
    if (!isRecord(compatibility)) {
      throw new Error(`Invalid spec in ${filePath}: execution.compatibility must be an object`);
    }

    if (!Array.isArray(compatibility.targets) || compatibility.targets.length === 0) {
      throw new Error(`Invalid spec in ${filePath}: execution.compatibility.targets must be a non-empty array`);
    }

    for (const [index, target] of compatibility.targets.entries()) {
      if (!isRecord(target)) {
        throw new Error(`Invalid spec in ${filePath}: execution.compatibility.targets[${index}] must be an object`);
      }
      if (!isNonEmptyString(target.os)) {
        throw new Error(`Invalid spec in ${filePath}: execution.compatibility.targets[${index}].os must be a non-empty string`);
      }
      if (!isNonEmptyString(target.kernel)) {
        throw new Error(`Invalid spec in ${filePath}: execution.compatibility.targets[${index}].kernel must be a non-empty string`);
      }
      if (!isNonEmptyString(target.arch)) {
        throw new Error(`Invalid spec in ${filePath}: execution.compatibility.targets[${index}].arch must be a non-empty string`);
      }
      if (
        "support" in target &&
        target.support !== undefined &&
        target.support !== "tested" &&
        target.support !== "declared"
      ) {
        throw new Error(
          `Invalid spec in ${filePath}: execution.compatibility.targets[${index}].support must be "tested" or "declared"`,
        );
      }
      if ("notes" in target && target.notes !== undefined && typeof target.notes !== "string") {
        throw new Error(`Invalid spec in ${filePath}: execution.compatibility.targets[${index}].notes must be a string`);
      }
    }
  }

  // Validate taskMode if present
  if (
    "taskMode" in spec.execution &&
    spec.execution.taskMode !== undefined &&
    spec.execution.taskMode !== "sync" &&
    spec.execution.taskMode !== "async"
  ) {
    throw new Error(
      `Invalid spec in ${filePath}: execution.taskMode must be "sync" or "async"`,
    );
  }

  const command = isRecord(spec.execution.command) ? spec.execution.command : undefined;
  const script = isRecord(spec.execution.script) ? spec.execution.script : undefined;
  const hasCommand = command !== undefined;
  const hasScript = script !== undefined;
  if (!hasCommand && !hasScript) {
    throw new Error(`Invalid spec in ${filePath}: execution.command or execution.script is required`);
  }
  if (hasCommand && hasScript) {
    throw new Error(`Invalid spec in ${filePath}: execution.command and execution.script cannot both be set`);
  }

  if (hasCommand) {
    if (typeof command.executable !== "string" || command.executable.length === 0) {
      throw new Error(`Invalid spec in ${filePath}: execution.command.executable is required`);
    }
  }

  if (hasScript) {
    if (typeof script.path !== "string" || script.path.length === 0) {
      throw new Error(`Invalid spec in ${filePath}: execution.script.path is required`);
    }
  }
}

async function loadSpecsFromDir(specDir: string): Promise<ShellToolSpec[]> {
  // Hierarchical structure: <specDir>/<serverName>/spec_yaml/*.yaml
  // __meta.specDir is set to the server directory (not spec_yaml/) so that
  // relative script paths like ./scripts/foo.sh resolve correctly.
  const topEntries = await readdir(specDir, { withFileTypes: true });
  const serverDirs = topEntries
    .filter((e) => e.isDirectory() && !e.name.startsWith("."))
    .map((e) => e.name);

  const specs: ShellToolSpec[] = [];
  for (const serverName of serverDirs) {
    const serverPath = path.join(specDir, serverName);
    const specYamlPath = path.join(serverPath, "spec_yaml");

    let yamlFileNames: string[];
    try {
      const entries = await readdir(specYamlPath);
      yamlFileNames = entries.filter((f) => f.endsWith(".yaml") || f.endsWith(".yml"));
    } catch {
      // No spec_yaml directory for this server, skip silently
      continue;
    }

    for (const file of yamlFileNames) {
      const filePath = path.join(specYamlPath, file);
      const raw = await readFile(filePath, "utf8");
      const parsed = parse(raw);
      assertSpec(parsed, filePath);
      // specDir points to server root, not spec_yaml subdir
      parsed.__meta = { specDir: serverPath };
      specs.push(parsed);
    }
  }

  return specs;
}

/**
 * Load shell tool specs from one or more directories.
 * When multiple directories are provided, later entries override earlier ones
 * for tools with the same name (user-defined tools take precedence over built-ins).
 */
export async function loadSpecs(specDirs: string | string[]): Promise<ShellToolSpec[]> {
  const dirs = Array.isArray(specDirs) ? specDirs : [specDirs];
  const merged = new Map<string, ShellToolSpec>();
  for (const dir of dirs) {
    const dirSpecs = await loadSpecsFromDir(dir);
    for (const spec of dirSpecs) {
      merged.set(spec.tool.name, spec);
    }
  }
  return Array.from(merged.values());
}
