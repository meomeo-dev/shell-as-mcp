import assert from "node:assert/strict";
import test from "node:test";
import { TaskStore } from "../src/task-store.js";

// UUID v4 正则，验证 create() 生成有效 UUID
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

test("test_create_returns_pending_entry_with_valid_uuid", () => {
  // Arrange
  const store = new TaskStore();

  // Act
  const entry = store.create("my_tool");

  // Assert
  assert.equal(entry.status, "pending");
  assert.equal(entry.toolName, "my_tool");
  assert.match(entry.taskId, UUID_RE);
  assert.equal(typeof entry.startedAt, "string");
  assert.equal(entry.stdout, "");
  assert.equal(entry.stderr, "");
});

test("test_get_returns_entry_by_id", () => {
  // Arrange
  const store = new TaskStore();
  const created = store.create("tool_a");

  // Act
  const found = store.get(created.taskId);

  // Assert
  assert.ok(found !== undefined);
  assert.equal(found.taskId, created.taskId);
  assert.equal(found.toolName, "tool_a");
});

test("test_get_returns_undefined_for_unknown_id", () => {
  // Arrange
  const store = new TaskStore();

  // Act
  const result = store.get("nonexistent-id");

  // Assert
  assert.equal(result, undefined);
});

test("test_list_returns_all_tasks_without_filter", () => {
  // Arrange
  const store = new TaskStore();
  store.create("tool_a");
  store.create("tool_b");
  store.create("tool_c");

  // Act
  const all = store.list();

  // Assert
  assert.equal(all.length, 3);
});

test("test_list_filters_by_status", () => {
  // Arrange
  const store = new TaskStore();
  const t1 = store.create("tool_a");
  const t2 = store.create("tool_b");
  store.create("tool_c");
  store.update(t1.taskId, { status: "completed" });
  store.update(t2.taskId, { status: "completed" });

  // Act
  const completed = store.list("completed");
  const pending = store.list("pending");

  // Assert
  assert.equal(completed.length, 2);
  assert.equal(pending.length, 1);
});

test("test_update_applies_partial_changes", () => {
  // Arrange
  const store = new TaskStore();
  const entry = store.create("tool_x");

  // Act
  const ok = store.update(entry.taskId, { status: "running", stdout: "hello" });

  // Assert
  assert.equal(ok, true);
  const updated = store.get(entry.taskId);
  assert.ok(updated !== undefined);
  assert.equal(updated.status, "running");
  assert.equal(updated.stdout, "hello");
  // taskId 不变
  assert.equal(updated.taskId, entry.taskId);
});

test("test_update_returns_false_for_unknown_id", () => {
  // Arrange
  const store = new TaskStore();

  // Act
  const ok = store.update("nonexistent-id", { status: "running" });

  // Assert
  assert.equal(ok, false);
});

test("test_delete_removes_task", () => {
  // Arrange
  const store = new TaskStore();
  const entry = store.create("tool_y");

  // Act
  const removed = store.delete(entry.taskId);
  const found = store.get(entry.taskId);

  // Assert
  assert.equal(removed, true);
  assert.equal(found, undefined);
});

test("test_cleanup_removes_all_terminal_tasks_without_maxAgeMs", () => {
  // Arrange
  const store = new TaskStore();
  const running = store.create("tool_run");
  store.update(running.taskId, { status: "running" });

  const completed = store.create("tool_done");
  store.update(completed.taskId, {
    status: "completed",
    completedAt: new Date().toISOString(),
  });

  const failed = store.create("tool_fail");
  store.update(failed.taskId, {
    status: "failed",
    completedAt: new Date().toISOString(),
  });

  // Act
  const count = store.cleanup();

  // Assert — completed + failed 被删除，running 保留
  assert.equal(count, 2);
  assert.ok(store.get(running.taskId) !== undefined);
  assert.equal(store.get(completed.taskId), undefined);
  assert.equal(store.get(failed.taskId), undefined);
});

test("test_cleanup_respects_maxAgeMs_for_old_tasks", () => {
  // Arrange
  const store = new TaskStore();

  // 旧任务：completedAt 设为 1 分钟前
  const oldTask = store.create("old_tool");
  const oneMinuteAgo = new Date(Date.now() - 60_000).toISOString();
  store.update(oldTask.taskId, {
    status: "completed",
    completedAt: oneMinuteAgo,
  });

  // 新任务：completedAt 设为刚刚完成
  const newTask = store.create("new_tool");
  store.update(newTask.taskId, {
    status: "completed",
    completedAt: new Date().toISOString(),
  });

  // Act — maxAgeMs=30_000 (30秒)：旧任务超龄，新任务未超龄
  const count = store.cleanup(30_000);

  // Assert — 只有超龄旧任务被删除
  assert.equal(count, 1);
  assert.equal(store.get(oldTask.taskId), undefined);
  assert.ok(store.get(newTask.taskId) !== undefined);
});
