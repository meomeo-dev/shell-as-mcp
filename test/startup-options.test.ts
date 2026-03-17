import assert from "node:assert/strict";
import test from "node:test";
import { parseStartupOptions } from "../src/startup-options.js";

test("parseStartupOptions uses stdio defaults", () => {
  const options = parseStartupOptions([], {}, "/repo");
  assert.equal(options.transport, "stdio");
  assert.equal(options.specDir, "/repo/shell_as_mcp_defs");
  assert.equal(options.host, "127.0.0.1");
  assert.equal(options.port, 3001);
  assert.equal(options.httpPath, "/mcp");
});

test("parseStartupOptions lets args override env values", () => {
  const options = parseStartupOptions(
    [
      "--transport",
      "streamable-http",
      "--spec-dir",
      "/tmp/specs",
      "--host",
      "0.0.0.0",
      "--port",
      "8080",
      "--http-path",
      "/rpc",
    ],
    {
      SHELL_AS_MCP_TRANSPORT: "stdio",
      SHELL_AS_MCP_SPEC_DIR: "/env/specs",
      SHELL_AS_MCP_HTTP_HOST: "127.0.0.1",
      SHELL_AS_MCP_HTTP_PORT: "3001",
      SHELL_AS_MCP_HTTP_PATH: "/mcp",
    },
    "/repo",
  );

  assert.equal(options.transport, "streamable-http");
  assert.equal(options.specDir, "/tmp/specs");
  assert.equal(options.host, "0.0.0.0");
  assert.equal(options.port, 8080);
  assert.equal(options.httpPath, "/rpc");
});

test("parseStartupOptions normalizes http-path when slash is omitted", () => {
  const options = parseStartupOptions(["--http-path", "rpc"], {}, "/repo");
  assert.equal(options.httpPath, "/rpc");
});

test("parseStartupOptions rejects unsupported transport", () => {
  assert.throws(
    () => parseStartupOptions(["--transport", "sse"], {}, "/repo"),
    /Unsupported transport/,
  );
});

test("parseStartupOptions rejects invalid port values", () => {
  assert.throws(
    () => parseStartupOptions(["--port", "abc"], {}, "/repo"),
    /Invalid port/,
  );
});

test("parseStartupOptions exits cleanly for --help", () => {
  const originalExit = process.exit;
  const originalWrite = process.stdout.write;
  let output = "";

  try {
    process.stdout.write = ((chunk: string | Uint8Array) => {
      output += chunk.toString();
      return true;
    }) as typeof process.stdout.write;

    process.exit = ((code?: number) => {
      throw new Error(`EXIT:${code ?? 0}`);
    }) as typeof process.exit;

    assert.throws(() => parseStartupOptions(["--help"], {}, "/repo"), /EXIT:0/);
    assert.match(output, /Usage: shell-as-mcp \[options\]/);
    assert.match(output, /-h, --help/);
  } finally {
    process.exit = originalExit;
    process.stdout.write = originalWrite;
  }
});

test("parseStartupOptions exits cleanly for -h", () => {
  const originalExit = process.exit;
  const originalWrite = process.stdout.write;
  let output = "";

  try {
    process.stdout.write = ((chunk: string | Uint8Array) => {
      output += chunk.toString();
      return true;
    }) as typeof process.stdout.write;

    process.exit = ((code?: number) => {
      throw new Error(`EXIT:${code ?? 0}`);
    }) as typeof process.exit;

    assert.throws(() => parseStartupOptions(["-h"], {}, "/repo"), /EXIT:0/);
    assert.match(output, /Usage: shell-as-mcp \[options\]/);
    assert.match(output, /-h, --help/);
  } finally {
    process.exit = originalExit;
    process.stdout.write = originalWrite;
  }
});
