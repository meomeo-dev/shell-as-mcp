import type { ExecutionResult } from "./types.js";

export type McpResponseMode = "content" | "structuredContent";

function formatStreamSection(name: "stdout" | "stderr", value: string): string {
  if (!value) {
    return `${name}: (empty)`;
  }

  return `${name}:\n${value}`;
}

export function formatExecutionResultForMcp(result: ExecutionResult, mode: McpResponseMode = "content") {
  const summary = [
    `status: ${result.status}`,
    `exit_code: ${result.exit_code}`,
    `command: ${result.command}`,
    `execution_time_ms: ${result.execution_time_ms}`,
    `spec_tool: ${result.spec_tool}`,
    formatStreamSection("stdout", result.stdout),
    formatStreamSection("stderr", result.stderr),
  ].join("\n");

  if (mode === "structuredContent") {
    return {
      isError: result.status === "error",
      content: [],
      structuredContent: result,
    };
  }

  return {
    isError: result.status === "error",
    content: [
      {
        type: "text" as const,
        text: summary,
      },
    ],
  };
}
