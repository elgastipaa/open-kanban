import assert from "node:assert/strict";
import { test } from "node:test";
import { RepetitionOperationStore } from "../../src/lib/daily-repetition-state.ts";

const command = (
  taskId,
  operationId,
  startOn = "2026-11-05",
  pattern = { frequency: "daily", interval: 1 },
) => ({
  operation_id: operationId,
  slug: "daily-board",
  task_id: taskId,
  start_on: startOn,
  end_on: null,
  occurrence_limit: 3,
  pattern,
  expected_due_on_version: 2,
  confirm_start_change: true,
  previous_series_id: null,
});

test("uncertain daily creation keeps the exact operation by task and board actor", () => {
  const ownerStore = new RepetitionOperationStore("owner", "daily-board");
  const collaboratorStore = new RepetitionOperationStore(
    "collaborator",
    "daily-board",
  );
  const pending = command("task-1", "operation-1");

  ownerStore.set(pending);

  assert.deepEqual(ownerStore.get("task-1"), pending);
  assert.equal(ownerStore.get("task-2"), null);
  assert.equal(collaboratorStore.get("task-1"), null);
  assert.equal(ownerStore.clear("task-1"), pending);
  assert.equal(ownerStore.get("task-1"), null);
});

test("a later command does not overwrite another task's uncertain result", () => {
  const operations = new RepetitionOperationStore("owner", "daily-board");
  const first = command("task-1", "operation-1", "2026-11-05", {
    frequency: "weekly",
    interval: 2,
    weekdays: [1, 3],
  });
  const second = command("task-2", "operation-2", "2026-11-07");

  operations.set(first);
  operations.set(second);

  assert.deepEqual(operations.get("task-1"), first);
  assert.deepEqual(operations.get("task-2"), second);
  operations.clearAll();
  assert.equal(operations.get("task-1"), null);
  assert.equal(operations.get("task-2"), null);
});

test("an uncertain yearly command keeps its exact calendar rule for retry", () => {
  const operations = new RepetitionOperationStore("owner", "daily-board");
  const pending = command("task-3", "operation-3", "2024-02-29", {
    frequency: "yearly",
    interval: "9223372036854775807",
    month: 2,
    day_of_month: 29,
  });

  operations.set(pending);

  assert.deepEqual(operations.get("task-3"), pending);
});
