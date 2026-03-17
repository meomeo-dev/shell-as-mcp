import { spawn } from "node:child_process";
import path from "node:path";
import type { ExecutionResult, ShellToolSpec } from "./types.js";
import type { TaskEntry, TaskStore } from "./task-store.js";

const DEFAULT_TIMEOUT_MS = 30_000;
const DEFAULT_MAX_OUTPUT_BYTES = 1_048_576;
const CONTROL_CHARS_EXCEPT_COMMON_WHITESPACE_REGEX = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;

function escapeControlCharacter(char: string): string {
  return `\\x${char.charCodeAt(0).toString(16).padStart(2, "0")}`;
}

export function sanitizeOutputText(content: string): string {
  return content.replace(CONTROL_CHARS_EXCEPT_COMMON_WHITESPACE_REGEX, escapeControlCharacter);
}

export function terminateChild(child: ReturnType<typeof spawn>): void {
  child.kill("SIGTERM");
  setTimeout(() => {
    if (child.exitCode === null) {
      child.kill("SIGKILL");
    }
  }, 500);
}

function appendError(existing: string, message: string): string {
  return existing ? `${existing}\n${message}` : message;
}

function renderTemplate(template: string, args: Record<string, unknown>): string {
  return template.replace(/\{\{\s*([\w.-]+)\s*\}\}/g, (_, key) => {
    const value = args[key];
    return value === undefined || value === null ? "" : String(value);
  });
}

function shellQuote(value: string): string {
  if (/^[a-zA-Z0-9_./:-]+$/.test(value)) {
    return value;
  }
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function resolveShell(spec: ShellToolSpec, args: Record<string, unknown>): { executable: string; args: string[] } {
  const shell = spec.execution.shell;
  if (!shell || shell.mode === "direct") {
    const executable = resolveCommandTarget(spec, args).commandExecutable;
    return { executable, args: [] };
  }

  const shellExecutable = shell.path ?? shell.name ?? "bash";
  const baseArgs = shell.args ?? (shell.name === "cmd" ? ["/c"] : ["-lc"]);
  return { executable: shellExecutable, args: baseArgs };
}

function resolveCommandTarget(
  spec: ShellToolSpec,
  args: Record<string, unknown>,
): { commandExecutable: string; commandArgs: string[] } {
  if (spec.execution.command) {
    return {
      commandExecutable: renderTemplate(spec.execution.command.executable, args),
      commandArgs: (spec.execution.command.args ?? []).map((arg) => renderTemplate(arg, args)),
    };
  }

  if (!spec.execution.script) {
    throw new Error(`Tool ${spec.tool.name} has neither execution.command nor execution.script`);
  }

  const renderedPath = renderTemplate(spec.execution.script.path, args);
  const scriptPath = path.isAbsolute(renderedPath)
    ? renderedPath
    : path.resolve(spec.__meta?.specDir ?? process.cwd(), renderedPath);
  const scriptArgs = (spec.execution.script.args ?? []).map((arg) => renderTemplate(arg, args));
  const interpreter = spec.execution.script.interpreter;
  if (interpreter) {
    return {
      commandExecutable: interpreter,
      commandArgs: [scriptPath, ...scriptArgs],
    };
  }

  return {
    commandExecutable: scriptPath,
    commandArgs: scriptArgs,
  };
}

export function buildExecutionPlan(spec: ShellToolSpec, args: Record<string, unknown>) {
  const { commandExecutable, commandArgs } = resolveCommandTarget(spec, args);
  const env: Record<string, string> = {
    ...Object.fromEntries(Object.entries(process.env).filter(([, value]) => value !== undefined) as [string, string][]),
  };

  for (const [envVar, source] of Object.entries(spec.execution.env?.fromRuntime ?? {})) {
    if (env[envVar] !== undefined && env[envVar] !== "") {
      continue;
    }
    const sourceNames = Array.isArray(source) ? source : [source];
    for (const sourceName of sourceNames) {
      const sourceValue = process.env[sourceName];
      if (sourceValue !== undefined && sourceValue !== "") {
        env[envVar] = sourceValue;
        break;
      }
    }
  }

  for (const [key, value] of Object.entries(spec.execution.env?.static ?? {})) {
    env[key] = renderTemplate(value, args);
  }

  for (const [envVar, paramName] of Object.entries(spec.execution.env?.fromParams ?? {})) {
    const value = args[paramName];
    if (value !== undefined && value !== null) {
      env[envVar] = String(value);
    }
  }

  const commandDisplay = [commandExecutable, ...commandArgs].map(shellQuote).join(" ");
  const shell = resolveShell(spec, args);
  const launchArgs =
    spec.execution.shell?.mode === "shell"
      ? [...shell.args, commandDisplay]
      : commandArgs;
  const executable = spec.execution.shell?.mode === "shell" ? shell.executable : commandExecutable;

  return {
    executable,
    launchArgs,
    commandDisplay,
    env,
    timeoutMs: spec.execution.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    maxOutputBytes: spec.execution.maxOutputBytes ?? DEFAULT_MAX_OUTPUT_BYTES,
    cwd: spec.execution.workingDirectory,
  };
}

export async function executeFromSpec(spec: ShellToolSpec, args: Record<string, unknown>): Promise<ExecutionResult> {
  const plan = buildExecutionPlan(spec, args);
  const start = Date.now();

  return new Promise<ExecutionResult>((resolve) => {
    const child = spawn(plan.executable, plan.launchArgs, {
      env: plan.env,
      cwd: plan.cwd,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let exceeded = false;

    const appendChunk = (
      target: "stdout" | "stderr",
      chunk: Buffer,
    ): void => {
      const content = sanitizeOutputText(chunk.toString("utf8"));
      if (target === "stdout") {
        stdout += content;
        if (Buffer.byteLength(stdout, "utf8") > plan.maxOutputBytes) {
          exceeded = true;
          terminateChild(child);
        }
        return;
      }

      stderr += content;
      if (Buffer.byteLength(stderr, "utf8") > plan.maxOutputBytes) {
        exceeded = true;
        terminateChild(child);
      }
    };

    const timer = setTimeout(() => {
      terminateChild(child);
      stderr = appendError(stderr, `Process timed out after ${plan.timeoutMs}ms`);
    }, plan.timeoutMs);

    child.stdout.on("data", (chunk: Buffer) => {
      appendChunk("stdout", chunk);
    });

    child.stderr.on("data", (chunk: Buffer) => {
      appendChunk("stderr", chunk);
    });

    child.on("close", (code) => {
      clearTimeout(timer);
      const status = code === 0 && !exceeded ? "success" : "error";
      if (exceeded) {
        stderr = appendError(stderr, `Output exceeded maxOutputBytes (${plan.maxOutputBytes}).`);
      }

      resolve({
        status,
        exit_code: code ?? -1,
        stdout: stdout.replace(/\n$/, ""),
        stderr: stderr.replace(/\n$/, ""),
        command: plan.commandDisplay,
        execution_time_ms: Date.now() - start,
        spec_tool: spec.tool.name,
      });
    });

    child.on("error", (error) => {
      clearTimeout(timer);
      resolve({
        status: "error",
        exit_code: -1,
        stdout,
        stderr: error.message,
        command: plan.commandDisplay,
        execution_time_ms: Date.now() - start,
        spec_tool: spec.tool.name,
      });
    });
  });
}

/**
 * 非阻塞地启动子进程并将执行状态写入 TaskEntry。
 * 与 executeFromSpec() 的区别：立即返回，不等待进程退出。
 * 调用者负责提供已在 TaskStore 中创建的 TaskEntry。
 */
export function spawnAndTrack(
  spec: ShellToolSpec,
  args: Record<string, unknown>,
  entry: TaskEntry,
  store: TaskStore,
): void {
  const plan = buildExecutionPlan(spec, args);

  const child = spawn(plan.executable, plan.launchArgs, {
    env: plan.env,
    cwd: plan.cwd,
    stdio: ["ignore", "pipe", "pipe"],
  });

  store.update(entry.taskId, { status: "running", process: child });

  let stdout = "";
  let stderr = "";
  let exceeded = false;

  const appendChunk = (
    target: "stdout" | "stderr",
    chunk: Buffer,
  ): void => {
    const content = sanitizeOutputText(chunk.toString("utf8"));
    if (target === "stdout") {
      stdout += content;
      store.update(entry.taskId, { stdout });
      if (Buffer.byteLength(stdout, "utf8") > plan.maxOutputBytes) {
        exceeded = true;
        terminateChild(child);
      }
      return;
    }

    stderr += content;
    store.update(entry.taskId, { stderr });
    if (Buffer.byteLength(stderr, "utf8") > plan.maxOutputBytes) {
      exceeded = true;
      terminateChild(child);
    }
  };

  const timer = setTimeout(() => {
    terminateChild(child);
    stderr = appendError(stderr, `Process timed out after ${plan.timeoutMs}ms`);
    store.update(entry.taskId, { stderr });
  }, plan.timeoutMs);

  child.stdout.on("data", (chunk: Buffer) => {
    appendChunk("stdout", chunk);
  });

  child.stderr.on("data", (chunk: Buffer) => {
    appendChunk("stderr", chunk);
  });

  child.on("close", (code) => {
    clearTimeout(timer);
    if (exceeded) {
      stderr = appendError(stderr, `Output exceeded maxOutputBytes (${plan.maxOutputBytes}).`);
    }
    const exitCode = code ?? -1;
    const status = exitCode === 0 && !exceeded ? "completed" : "failed";
    const completedAt = new Date().toISOString();
    store.update(entry.taskId, {
      status,
      exitCode,
      completedAt,
      stdout: stdout.replace(/\n$/, ""),
      stderr: stderr.replace(/\n$/, ""),
      process: undefined,
    });
  });

  child.on("error", (error) => {
    clearTimeout(timer);
    const completedAt = new Date().toISOString();
    store.update(entry.taskId, {
      status: "failed",
      errorMessage: error.message,
      completedAt,
      process: undefined,
    });
  });
}
