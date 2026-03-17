import { randomUUID } from "node:crypto";
import type { ChildProcess } from "node:child_process";

export class ConcurrencyLimitError extends Error {
  constructor(current: number, max: number) {
    super(`Concurrency limit reached: ${current}/${max} active tasks`);
    this.name = "ConcurrencyLimitError";
  }
}

export type TaskStatus =
  | "pending"
  | "running"
  | "completed"
  | "failed"
  | "cancelled";

export interface TaskEntry {
  /** UUID generated via crypto.randomUUID() */
  taskId: string;
  /** spec.tool.name — enables __task_list filtering by tool */
  toolName: string;
  status: TaskStatus;
  /** ISO 8601 — set at creation time */
  startedAt: string;
  /** ISO 8601 — set after process close event */
  completedAt?: string;
  /** Accumulated stdout text (bounded by maxOutputBytes in executor) */
  stdout: string;
  /** Accumulated stderr text (bounded by maxOutputBytes in executor) */
  stderr: string;
  /** Process exit code; undefined while running */
  exitCode?: number;
  /** Diagnostic message for timeout / output-limit / spawn errors */
  errorMessage?: string;
  /** Child process reference for cancellation; cleared after exit */
  process?: ChildProcess;
}

export interface TaskStoreOptions {
  /** Maximum number of active (pending + running) tasks allowed. Defaults to unlimited. */
  maxConcurrent?: number;
}

export class TaskStore {
  private readonly store = new Map<string, TaskEntry>();
  private readonly maxConcurrent: number | undefined;

  constructor(options: TaskStoreOptions = {}) {
    this.maxConcurrent = options.maxConcurrent;
  }

  /** Create a new task in "pending" state and return its entry. */
  create(toolName: string): TaskEntry {
    if (this.maxConcurrent !== undefined) {
      const activeCount = Array.from(this.store.values()).filter(
        (e) => e.status === "pending" || e.status === "running",
      ).length;
      if (activeCount >= this.maxConcurrent) {
        throw new ConcurrencyLimitError(activeCount, this.maxConcurrent);
      }
    }
    const entry: TaskEntry = {
      taskId: randomUUID(),
      toolName,
      status: "pending",
      startedAt: new Date().toISOString(),
      stdout: "",
      stderr: "",
    };
    this.store.set(entry.taskId, entry);
    return entry;
  }

  /** Return the TaskEntry for the given taskId, or undefined if not found. */
  get(taskId: string): TaskEntry | undefined {
    return this.store.get(taskId);
  }

  /** List all tasks, optionally filtered by status. */
  list(statusFilter?: TaskStatus): TaskEntry[] {
    const entries = Array.from(this.store.values());
    return statusFilter
      ? entries.filter((e) => e.status === statusFilter)
      : entries;
  }

  /**
   * Apply partial updates to an existing task.
   * Returns true if the task was found and updated, false otherwise.
   */
  update(
    taskId: string,
    updates: Partial<Omit<TaskEntry, "taskId">>
  ): boolean {
    const entry = this.store.get(taskId);
    if (!entry) return false;
    Object.assign(entry, updates);
    return true;
  }

  /** Delete a task by taskId. Returns true if it existed. */
  delete(taskId: string): boolean {
    return this.store.delete(taskId);
  }

  /**
   * Remove terminal-state tasks (completed / failed / cancelled).
   * If maxAgeMs is provided, only remove tasks whose completedAt is
   * older than maxAgeMs milliseconds.  If undefined, remove all terminal tasks.
   * Returns the number of tasks removed.
   */
  cleanup(maxAgeMs?: number): number {
    const terminalStatuses: TaskStatus[] = [
      "completed",
      "failed",
      "cancelled",
    ];
    const now = Date.now();
    let removed = 0;

    for (const [id, entry] of this.store.entries()) {
      if (!terminalStatuses.includes(entry.status)) continue;

      if (maxAgeMs !== undefined) {
        const completedAt = entry.completedAt
          ? new Date(entry.completedAt).getTime()
          : undefined;
        if (completedAt === undefined || now - completedAt < maxAgeMs) {
          continue;
        }
      }

      this.store.delete(id);
      removed++;
    }

    return removed;
  }
}

/**
 * Default singleton task store (unlimited concurrency).
 * For concurrency-bounded usage, create a new TaskStore({ maxConcurrent: n }) instead.
 */
export const globalTaskStore = new TaskStore();
