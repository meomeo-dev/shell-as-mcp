import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { terminateChild } from "./executor.js";
import type { TaskEntry, TaskStore, TaskStatus } from "./task-store.js";

/** Public summary shape — omits bulky stdout/stderr and internal process ref. */
type TaskSummary = Omit<TaskEntry, "stdout" | "stderr" | "process">;

function toSummary(entry: TaskEntry): TaskSummary {
  const { stdout: _stdout, stderr: _stderr, process: _proc, ...summary } = entry;
  return summary;
}

function toDetail(entry: TaskEntry): Omit<TaskEntry, "process"> {
  const { process: _proc, ...detail } = entry;
  return detail;
}

const TERMINAL_STATUSES: ReadonlySet<TaskStatus> = new Set([
  "completed",
  "failed",
  "cancelled",
]);

/**
 * Register the 4 built-in task-management MCP tools onto `server`.
 * Call this once from index.ts after creating the McpServer instance.
 */
export function registerTaskManagementTools(
  server: McpServer,
  store: TaskStore,
): void {
  // ── builtin__bg_task_list ────────────────────────────────────────────────────────────
  server.registerTool(
    "builtin__bg_task_list",
    {
      description:
        "List all background tasks. Optionally filter by status.",
      inputSchema: z.object({
        status: z
          .enum(["pending", "running", "completed", "failed", "cancelled"])
          .optional(),
      }),
    },
    async (args) => {
      const tasks = store.list(args.status as TaskStatus | undefined);
      const summaries: TaskSummary[] = tasks.map(toSummary);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              { tasks: summaries, total: summaries.length },
              null,
              2,
            ),
          },
        ],
      };
    },
  );

  // ── builtin__bg_task_get ─────────────────────────────────────────────────────────────
  server.registerTool(
    "builtin__bg_task_get",
    {
      description:
        "Get full details of a background task by taskId, including stdout/stderr output.",
      inputSchema: z.object({
        taskId: z.string(),
      }),
    },
    async (args) => {
      const entry = store.get(args.taskId);
      if (!entry) {
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify(
                { error: "Task not found", taskId: args.taskId },
                null,
                2,
              ),
            },
          ],
          isError: true,
        };
      }
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(toDetail(entry), null, 2),
          },
        ],
      };
    },
  );

  // ── builtin__bg_task_cancel ──────────────────────────────────────────────────────────
  server.registerTool(
    "builtin__bg_task_cancel",
    {
      description:
        "Cancel a running background task. Sends SIGTERM followed by SIGKILL if needed.",
      inputSchema: z.object({
        taskId: z.string(),
      }),
    },
    async (args) => {
      const { taskId } = args;
      const entry = store.get(taskId);

      if (!entry) {
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify(
                { success: false, message: "Task not found" },
                null,
                2,
              ),
            },
          ],
        };
      }

      if (TERMINAL_STATUSES.has(entry.status)) {
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify(
                {
                  success: false,
                  message: `Task already in terminal state: ${entry.status}`,
                },
                null,
                2,
              ),
            },
          ],
        };
      }

      if (entry.process) {
        terminateChild(entry.process);
      }

      store.update(taskId, {
        status: "cancelled",
        completedAt: new Date().toISOString(),
        errorMessage: "Cancelled by user",
      });

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                success: true,
                message: "Task cancellation requested",
                taskId,
              },
              null,
              2,
            ),
          },
        ],
      };
    },
  );

  // ── builtin__bg_task_cleanup ─────────────────────────────────────────────────────────
  server.registerTool(
    "builtin__bg_task_cleanup",
    {
      description:
        "Remove completed, failed, or cancelled tasks from memory. " +
        "Optionally specify maxAgeMs to only remove tasks older than the given milliseconds.",
      inputSchema: z.object({
        maxAgeMs: z.number().int().min(0).optional(),
      }),
    },
    async (args) => {
      const cleaned = store.cleanup(args.maxAgeMs);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              { cleaned, remaining: store.list().length },
              null,
              2,
            ),
          },
        ],
      };
    },
  );
}
