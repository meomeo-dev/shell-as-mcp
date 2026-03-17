#!/usr/bin/env node

import { spawn } from "node:child_process";
import process from "node:process";

function parseArgs(argv) {
  const parsed = { commandJson: "", cwd: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const item = argv[i];
    if (item === "--command-json") {
      parsed.commandJson = argv[i + 1] ?? "";
      i += 1;
      continue;
    }
    if (item === "--cwd") {
      parsed.cwd = argv[i + 1] ?? "";
      i += 1;
      continue;
    }
  }
  return parsed;
}

function quoteShellArg(value) {
  if (/^[a-zA-Z0-9_./:@%+=,-]+$/.test(value)) {
    return value;
  }
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function parseListEnv(name, defaults = []) {
  const value = process.env[name] ?? "";
  if (!value.trim()) {
    return defaults;
  }
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function buildConfig(cwd) {
  const allowWriteDefaults = cwd ? [cwd, "/tmp"] : ["/tmp"];
  return {
    network: {
      allowedDomains: parseListEnv("SHELL_AS_MCP_SANDBOX_ALLOWED_DOMAINS"),
      deniedDomains: parseListEnv("SHELL_AS_MCP_SANDBOX_DENIED_DOMAINS"),
    },
    filesystem: {
      denyRead: parseListEnv("SHELL_AS_MCP_SANDBOX_DENY_READ", [
        "~/.ssh",
        "~/.aws",
        "~/.gnupg",
      ]),
      allowWrite: parseListEnv(
        "SHELL_AS_MCP_SANDBOX_ALLOW_WRITE",
        allowWriteDefaults,
      ),
      denyWrite: parseListEnv("SHELL_AS_MCP_SANDBOX_DENY_WRITE", [".env"]),
    },
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.commandJson) {
    console.error("missing --command-json");
    process.exit(2);
  }

  let commandParts;
  try {
    commandParts = JSON.parse(args.commandJson);
  } catch (error) {
    console.error(`invalid --command-json: ${String(error)}`);
    process.exit(2);
  }

  if (!Array.isArray(commandParts) || commandParts.length === 0) {
    console.error("command-json must be a non-empty string array");
    process.exit(2);
  }

  let SandboxManager;
  try {
    ({ SandboxManager } = await import("@anthropic-ai/sandbox-runtime"));
  } catch (error) {
    console.error("@anthropic-ai/sandbox-runtime is not installed");
    console.error(String(error));
    process.exit(127);
  }

  const dependencies = SandboxManager.checkDependencies();
  if (dependencies.errors.length > 0) {
    console.error(`sandbox dependencies missing: ${dependencies.errors.join("; ")}`);
    process.exit(127);
  }

  const cwd = args.cwd || process.cwd();
  const config = buildConfig(cwd);
  const commandLine = commandParts.map((part) => quoteShellArg(String(part))).join(" ");

  await SandboxManager.initialize(config);
  let exitCode = 1;

  try {
    const sandboxed = await SandboxManager.wrapWithSandbox(commandLine);
    const child = spawn(sandboxed, {
      shell: true,
      cwd,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    child.stdout.on("data", (chunk) => process.stdout.write(chunk));
    child.stderr.on("data", (chunk) => process.stderr.write(chunk));

    exitCode = await new Promise((resolve, reject) => {
      child.on("error", reject);
      child.on("close", (code) => resolve(code ?? 1));
    });
  } finally {
    await SandboxManager.reset();
  }

  process.exit(exitCode);
}

main().catch((error) => {
  console.error(String(error));
  process.exit(1);
});
