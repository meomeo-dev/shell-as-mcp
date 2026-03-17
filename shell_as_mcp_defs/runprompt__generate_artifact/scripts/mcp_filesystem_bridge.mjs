#!/usr/bin/env node

import process from "node:process";
import { Buffer } from "node:buffer";
import { Client } from "@modelcontextprotocol/sdk/client";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

function parseArgs(argv) {
  const parsed = {
    root: "",
    op: "",
    path: "",
    contentBase64: "",
    oldTextBase64: "",
    newTextBase64: "",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    const value = argv[i + 1] ?? "";
    if (key === "--root") {
      parsed.root = value;
      i += 1;
      continue;
    }
    if (key === "--op") {
      parsed.op = value;
      i += 1;
      continue;
    }
    if (key === "--path") {
      parsed.path = value;
      i += 1;
      continue;
    }
    if (key === "--content-base64") {
      parsed.contentBase64 = value;
      i += 1;
      continue;
    }
    if (key === "--old-text-base64") {
      parsed.oldTextBase64 = value;
      i += 1;
      continue;
    }
    if (key === "--new-text-base64") {
      parsed.newTextBase64 = value;
      i += 1;
      continue;
    }
  }
  return parsed;
}

function parseServerArgs() {
  const json = process.env.SHELL_AS_MCP_FILESYSTEM_SERVER_ARGS_JSON ?? "";
  if (json.trim()) {
    return JSON.parse(json);
  }
  const raw =
    process.env.SHELL_AS_MCP_FILESYSTEM_SERVER_ARGS ??
    "-y @modelcontextprotocol/server-filesystem";
  return raw
    .trim()
    .split(/\s+/)
    .filter(Boolean);
}

function extractText(result) {
  if (typeof result?.structuredContent === "string") {
    return result.structuredContent;
  }
  const content = result?.content;
  if (!Array.isArray(content)) {
    return "";
  }
  const parts = content
    .filter((item) => item?.type === "text")
    .map((item) => item.text ?? "");
  return parts.join("\n");
}

async function callTool(client, name, args) {
  return client.callTool({ name, arguments: args });
}

async function writeViaTools(client, filePath, content, toolNames) {
  if (toolNames.has("write_file")) {
    await callTool(client, "write_file", { path: filePath, content });
    return;
  }

  if (toolNames.has("create_file")) {
    if (toolNames.has("delete_file")) {
      try {
        await callTool(client, "delete_file", { path: filePath });
      } catch {
        // Ignore when target does not exist.
      }
    }
    await callTool(client, "create_file", { path: filePath, content });
    return;
  }

  throw new Error("Neither write_file nor create_file is available");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const needsPath = args.op !== "list-tools";
  if (!args.root || !args.op || (needsPath && !args.path)) {
    console.error(
      "usage: --root <dir> --op <mkdir|write|read|edit|delete|list-tools> --path <path>",
    );
    process.exit(2);
  }

  const serverCommand =
    process.env.SHELL_AS_MCP_FILESYSTEM_SERVER_COMMAND ?? "npx";
  const serverArgs = [...parseServerArgs(), args.root];

  const client = new Client({ name: "shell-as-mcp-fs-bridge", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: serverCommand,
    args: serverArgs,
    stderr: "pipe",
  });

  const stderrChunks = [];
  if (transport.stderr) {
    transport.stderr.on("data", (chunk) => {
      stderrChunks.push(String(chunk));
    });
  }

  try {
    await client.connect(transport);
    const tools = await client.listTools();
    const toolNames = new Set((tools.tools ?? []).map((item) => item.name));

    if (args.op === "list-tools") {
      process.stdout.write(
        JSON.stringify(
          {
            tools: Array.from(toolNames).sort(),
          },
          null,
          2,
        ),
      );
      return;
    }

    if (args.op === "mkdir") {
      await callTool(client, "create_directory", { path: args.path });
      return;
    }

    if (args.op === "write") {
      const content = Buffer.from(args.contentBase64, "base64").toString("utf-8");
      await writeViaTools(client, args.path, content, toolNames);
      return;
    }

    if (args.op === "read") {
      const toolName = toolNames.has("read_text_file")
        ? "read_text_file"
        : "read_file";
      if (!toolNames.has(toolName)) {
        console.error("No compatible read tool available on filesystem server");
        process.exit(2);
      }
      const result = await callTool(client, toolName, { path: args.path });
      process.stdout.write(extractText(result));
      return;
    }

    if (args.op === "edit") {
      if (!args.oldTextBase64 && !args.newTextBase64) {
        console.error("edit op requires --old-text-base64 and --new-text-base64");
        process.exit(2);
      }
      if (!toolNames.has("edit_file")) {
        console.error("edit_file is not available on filesystem server");
        process.exit(2);
      }
      const oldText = Buffer.from(args.oldTextBase64, "base64").toString("utf-8");
      const newText = Buffer.from(args.newTextBase64, "base64").toString("utf-8");
      const result = await callTool(client, "edit_file", {
        path: args.path,
        edits: [{ oldText, newText }],
        dryRun: false,
      });
      process.stdout.write(extractText(result));
      return;
    }

    if (args.op === "delete") {
      if (!toolNames.has("delete_file")) {
        console.error("delete_file is not available on filesystem server");
        process.exit(2);
      }
      await callTool(client, "delete_file", { path: args.path });
      return;
    }

    console.error(`unsupported op: ${args.op}`);
    process.exit(2);
  } catch (error) {
    const bridgeStderr = stderrChunks.join("").trim();
    if (bridgeStderr) {
      console.error(bridgeStderr);
    }
    console.error(String(error));
    process.exit(1);
  } finally {
    await client.close();
  }
}

main().catch((error) => {
  console.error(String(error));
  process.exit(1);
});
