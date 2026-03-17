import path from "node:path";
import { parseArgs } from "node:util";

export type TransportType = "stdio" | "streamable-http";

export interface StartupOptions {
  specDir: string;
  transport: TransportType;
  host: string;
  port: number;
  httpPath: string;
  maxConcurrentTasks?: number;
}

export function parseStartupOptions(
  argv: string[] = process.argv.slice(2),
  env: NodeJS.ProcessEnv = process.env,
  cwd: string = process.cwd(),
): StartupOptions {
  const { values } = parseArgs({
    args: argv,
    options: {
      transport: { type: "string" },
      "spec-dir": { type: "string" },
      host: { type: "string" },
      port: { type: "string" },
      "http-path": { type: "string" },
      "max-concurrent-tasks": { type: "string" },
      help: { type: "boolean", short: "h" },
    },
    strict: true,
    allowPositionals: false,
  });

  if (values.help) {
    process.stdout.write(
      [
        "Usage: shell-as-mcp [options]",
        "",
        "Options:",
        "  --transport <stdio|streamable-http>  Transport mode (default: stdio)",
        "  --spec-dir <path>                    Tool spec directory (default: ./shell_as_mcp_defs)",
        "  --host <host>                        HTTP host (default: 127.0.0.1)",
        "  --port <port>                        HTTP port (default: 3001)",
        "  --http-path <path>                   HTTP endpoint path (default: /mcp)",
        "  --max-concurrent-tasks <n>           Max parallel async background tasks (default: unlimited)",
        "  -h, --help                           Show this help message",
        "",
      ].join("\n"),
    );
    process.exit(0);
  }

  const transportRaw = values.transport ?? env.SHELL_AS_MCP_TRANSPORT ?? "stdio";
  if (transportRaw !== "stdio" && transportRaw !== "streamable-http") {
    throw new Error(
      `Unsupported transport "${transportRaw}". Supported values: stdio, streamable-http.`,
    );
  }

  const host = values.host ?? env.SHELL_AS_MCP_HTTP_HOST ?? "127.0.0.1";
  const portRaw = values.port ?? env.SHELL_AS_MCP_HTTP_PORT ?? "3001";
  const port = Number(portRaw);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Invalid port "${portRaw}". Expected integer in range 1-65535.`);
  }

  const httpPathRaw = values["http-path"] ?? env.SHELL_AS_MCP_HTTP_PATH ?? "/mcp";
  const httpPath = normalizeHttpPath(httpPathRaw);

  return {
    transport: transportRaw,
    specDir: values["spec-dir"] ?? env.SHELL_AS_MCP_SPEC_DIR ?? path.join(cwd, "shell_as_mcp_defs"),
    host,
    port,
    httpPath,
    maxConcurrentTasks: parseMaxConcurrentTasks(
      values["max-concurrent-tasks"] ?? env.SHELL_AS_MCP_MAX_CONCURRENT_TASKS,
    ),
  };
}

function normalizeHttpPath(rawPath: string): string {
  if (rawPath.length === 0) {
    return "/mcp";
  }
  if (rawPath.startsWith("/")) {
    return rawPath;
  }
  return `/${rawPath}`;
}

function parseMaxConcurrentTasks(raw: string | undefined): number | undefined {
  if (raw === undefined) return undefined;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1) {
    throw new Error(
      `Invalid max-concurrent-tasks "${raw}". Expected positive integer.`,
    );
  }
  return n;
}
