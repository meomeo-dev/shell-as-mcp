export type PrimitiveType = "string" | "number" | "integer" | "boolean";

export interface ToolInputProperty {
  type: PrimitiveType;
  description?: string;
}

export interface ToolInputSchema {
  properties: Record<string, ToolInputProperty>;
  required?: string[];
}

export interface ToolOutputSchema {
  type: "object";
  properties: Record<string, { type: string; description?: string }>;
  required?: string[];
}

export interface ShellConfig {
  mode: "direct" | "shell";
  name?: "bash" | "zsh" | "sh" | "pwsh" | "cmd";
  path?: string;
  args?: string[];
}

export interface EnvConfig {
  static?: Record<string, string>;
  fromParams?: Record<string, string>;
  fromRuntime?: Record<string, string | string[]>;
}

export interface CommandConfig {
  executable: string;
  args?: string[];
}

export interface ScriptConfig {
  path: string;
  args?: string[];
  interpreter?: string;
}

export interface ShellToolSpec {
  apiVersion: "v1";
  tool: {
    name: string;
    description: string;
    input: ToolInputSchema;
    output: ToolOutputSchema;
  };
  execution: {
    shell?: ShellConfig;
    env?: EnvConfig;
    workingDirectory?: string;
    timeoutMs?: number;
    maxOutputBytes?: number;
    taskMode?: "sync" | "async";
    command?: CommandConfig;
    script?: ScriptConfig;
  };
  __meta?: {
    specDir: string;
  };
}

export interface ExecutionResult {
  [key: string]: unknown;
  status: "success" | "error";
  exit_code: number;
  stdout: string;
  stderr: string;
  command: string;
  execution_time_ms: number;
  spec_tool: string;
}
