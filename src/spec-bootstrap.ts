import { mkdir, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Ensures the user-defined spec directory exists (creates it if needed).
 * Bundled specs are always loaded directly from the package; this directory
 * is an overlay — user tools with the same name take precedence over built-ins.
 */
export async function ensureSpecDirectoryReady(targetSpecDir: string): Promise<void> {
  await mkdir(path.resolve(targetSpecDir), { recursive: true });
}

export async function resolveBundledSpecDir(moduleFileUrl: string): Promise<string> {
  const moduleDir = path.dirname(fileURLToPath(moduleFileUrl));
  const candidates = [
    path.resolve(moduleDir, "../shell_as_mcp_defs"),
    path.resolve(moduleDir, "../../shell_as_mcp_defs"),
  ];

  for (const candidate of candidates) {
    if (await existsDirectory(candidate)) {
      return candidate;
    }
  }

  throw new Error("Unable to locate bundled specs directory. Ensure package includes ./shell_as_mcp_defs.");
}

async function existsDirectory(filePath: string): Promise<boolean> {
  try {
    const stats = await stat(filePath);
    return stats.isDirectory();
  } catch {
    return false;
  }
}
