import assert from "node:assert/strict";
import path from "node:path";
import net from "node:net";
import { spawn, type ChildProcess } from "node:child_process";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
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

async function getFreePort(): Promise<number> {
  return await new Promise<number>((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close();
        reject(new Error("failed to allocate free port"));
        return;
      }
      const port = address.port;
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(port);
      });
    });
  });
}

function startHttpServerProcess(repoRoot: string, port: number): {
  child: ChildProcess;
  waitForReady: Promise<void>;
  stderrChunks: string[];
} {
  const serverEntry = path.join(repoRoot, "src", "index.ts");
  const child = spawn(
    process.execPath,
    ["--import", "tsx", serverEntry, "--transport", "streamable-http", "--host", "127.0.0.1", "--port", String(port), "--http-path", "/mcp"],
    {
      cwd: repoRoot,
      env: {
        ...process.env,
        SHELL_AS_MCP_TRANSPORT: "streamable-http",
      } as Record<string, string>,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );

  const stderrChunks: string[] = [];
  const stdoutChunks: string[] = [];

  child.stderr.on("data", (chunk: Buffer | string) => {
    const text = chunk.toString();
    stderrChunks.push(text);
  });
  child.stdout.on("data", (chunk: Buffer | string) => {
    stdoutChunks.push(chunk.toString());
  });

  const waitForReady = new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error(`streamable-http server startup timeout\nSTDOUT:\n${stdoutChunks.join("")}\nSTDERR:\n${stderrChunks.join("")}`));
    }, 15_000);

    const onData = (chunk: Buffer | string) => {
      const text = chunk.toString();
      if (text.includes("streamable-http at http://127.0.0.1:")) {
        clearTimeout(timeout);
        child.stderr.off("data", onData);
        resolve();
      }
    };

    child.stderr.on("data", onData);

    child.once("exit", (code) => {
      clearTimeout(timeout);
      reject(new Error(`streamable-http server exited early with code ${code}\nSTDOUT:\n${stdoutChunks.join("")}\nSTDERR:\n${stderrChunks.join("")}`));
    });
  });

  return { child, waitForReady, stderrChunks };
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

test(
  "shell-as-mcp can initialize and serve tools over streamable-http RPC",
  { timeout: 45_000 },
  async () => {
    const repoRoot = process.cwd();
    const port = await getFreePort();
    const { child, waitForReady, stderrChunks } = startHttpServerProcess(repoRoot, port);

    const client = new Client(
      { name: "shell-as-mcp-http-e2e-client", version: "1.0.0" },
      { capabilities: {} },
    );
    const transport = new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`));

    try {
      await waitForReady;
      await client.connect(transport);

      const toolsResult = await client.listTools();
      assert.ok(toolsResult.tools.length > 0, "streamable-http should expose at least one tool");

      const loadedSpecs = await loadSpecs(path.join(repoRoot, "shell_as_mcp_defs"));
      const expectedToolNames = loadedSpecs.map((spec) => spec.tool.name);
      const actualToolNames = new Set(toolsResult.tools.map((tool) => tool.name));

      for (const toolName of expectedToolNames) {
        assert.ok(actualToolNames.has(toolName), `expected tool to be exposed via streamable-http RPC: ${toolName}`);
      }
    } catch (error) {
      const stderrText = stderrChunks.join("").trim();
      if (stderrText.length > 0) {
        throw new Error(`${String(error)}\nServer stderr:\n${stderrText}`);
      }
      throw error;
    } finally {
      await client.close().catch(() => undefined);
      child.kill("SIGTERM");
      await new Promise((resolve) => child.once("exit", resolve));
    }
  },
);
