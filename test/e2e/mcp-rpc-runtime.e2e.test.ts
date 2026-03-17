import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { loadSpecs } from "../../src/spec-loader.js";
import { MCP_RESPONSE_MODE_PARAM } from "../../src/schema.js";

function createClientContext(repoRoot: string) {
  const serverEntry = path.join(repoRoot, "src", "index.ts");

  const client = new Client(
    { name: "shell-as-mcp-rpc-e2e-client", version: "1.0.0" },
    { capabilities: {} },
  );

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["--import", "tsx", serverEntry, "--transport", "stdio"],
    cwd: repoRoot,
    env: {
      ...process.env,
      SHELL_AS_MCP_TRANSPORT: "stdio",
    } as Record<string, string>,
    stderr: "pipe",
  });

  const stderrChunks: string[] = [];
  transport.stderr?.on("data", (chunk: Buffer | string) => {
    stderrChunks.push(chunk.toString());
  });

  return { client, transport, stderrChunks };
}

test(
  "shell-as-mcp can initialize and serve tools over stdio RPC",
  { timeout: 30_000 },
  async () => {
    const repoRoot = process.cwd();
    const specDir = path.join(repoRoot, "shell_as_mcp_defs");
    const { client, transport, stderrChunks } = createClientContext(repoRoot);

    try {
      await client.connect(transport);

      const pingResult = await client.ping();
      assert.ok(pingResult);

      const toolsResult = await client.listTools();
      assert.ok(toolsResult.tools.length > 0, "server should expose at least one tool");

      const loadedSpecs = await loadSpecs(specDir);
      const expectedToolNames = loadedSpecs.map((spec) => spec.tool.name);
      const actualToolNames = new Set(toolsResult.tools.map((tool) => tool.name));

      for (const toolName of expectedToolNames) {
        assert.ok(actualToolNames.has(toolName), `expected tool to be exposed via RPC: ${toolName}`);
      }

      const serverVersion = client.getServerVersion();
      assert.ok(serverVersion?.version, "server version should be negotiated");
    } catch (error) {
      const stderrText = stderrChunks.join("").trim();
      if (stderrText.length > 0) {
        throw new Error(`${String(error)}\nServer stderr:\n${stderrText}`);
      }
      throw error;
    } finally {
      await client.close();
    }
  },
);

test(
  "shell-as-mcp executes all healthz tools over stdio RPC",
  { timeout: 60_000 },
  async () => {
    const repoRoot = process.cwd();
    const specDir = path.join(repoRoot, "shell_as_mcp_defs");
    const { client, transport, stderrChunks } = createClientContext(repoRoot);

    try {
      await client.connect(transport);

      const loadedSpecs = await loadSpecs(specDir);
      const healthzToolNames = loadedSpecs
        .map((spec) => spec.tool.name)
        .filter((toolName) => toolName.endsWith("__healthz"));

      assert.ok(healthzToolNames.length > 0, "expected at least one healthz tool");

      for (const toolName of healthzToolNames) {
        const result = await client.callTool({
          name: toolName,
          arguments: {
            [MCP_RESPONSE_MODE_PARAM]: "structuredContent",
          },
        });

        assert.equal(result.isError, false, `healthz tool failed: ${toolName}`);
        const structured = result.structuredContent as Record<string, unknown> | undefined;
        assert.ok(structured, `structuredContent missing for ${toolName}`);
        assert.equal(structured.spec_tool, toolName, `spec_tool mismatch for ${toolName}`);
        assert.equal(typeof structured.command, "string", `command missing for ${toolName}`);
        assert.equal(
          typeof structured.execution_time_ms,
          "number",
          `execution_time_ms missing for ${toolName}`,
        );
        assert.equal(structured.status, "success", `unexpected status for ${toolName}`);
      }
    } catch (error) {
      const stderrText = stderrChunks.join("").trim();
      if (stderrText.length > 0) {
        throw new Error(`${String(error)}\nServer stderr:\n${stderrText}`);
      }
      throw error;
    } finally {
      await client.close();
    }
  },
);
