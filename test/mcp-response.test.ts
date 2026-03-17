import assert from "node:assert/strict";
import test from "node:test";
import { formatExecutionResultForMcp } from "../src/mcp-response.js";

test("formats execution result with explicit status and readable text content", () => {
  const result = formatExecutionResultForMcp({
    status: "success",
    exit_code: 0,
    stdout: "ok",
    stderr: "",
    command: "echo ok",
    execution_time_ms: 12,
    spec_tool: "echo_tool",
  });

  assert.equal(result.isError, false);
  assert.ok(result.content);
  assert.equal(result.content[0]?.type, "text");
  assert.match(result.content[0]?.text ?? "", /status: success/);
  assert.match(result.content[0]?.text ?? "", /stdout:\nok/);
  assert.match(result.content[0]?.text ?? "", /stderr: \(empty\)/);
  assert.equal("structuredContent" in result, false);
});

test("marks failed execution as MCP tool error", () => {
  const result = formatExecutionResultForMcp({
    status: "error",
    exit_code: 1,
    stdout: "",
    stderr: "boom",
    command: "false",
    execution_time_ms: 5,
    spec_tool: "failing_tool",
  });

  assert.equal(result.isError, true);
  assert.ok(result.content);
  assert.match(result.content[0]?.text ?? "", /status: error/);
});

test("returns structuredContent only when structured mode is selected", () => {
  const result = formatExecutionResultForMcp(
    {
      status: "success",
      exit_code: 0,
      stdout: "ok",
      stderr: "",
      command: "echo ok",
      execution_time_ms: 12,
      spec_tool: "echo_tool",
    },
    "structuredContent",
  );

  assert.equal(result.isError, false);
  assert.equal(result.content.length, 0);
  assert.ok(result.structuredContent);
  assert.equal(result.structuredContent.status, "success");
});
