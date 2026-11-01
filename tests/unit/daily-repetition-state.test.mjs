import assert from "node:assert/strict";
import { test } from "node:test";
import { DailyRepetitionOperationStore } from "../../src/lib/daily-repetition-state.ts";

const command = (taskId, operationId, startOn = "2026-11-05") => ({
  operation_id: operationId,
  slug: "daily-board",
  task_id: taskId,
  start_on: startOn,
  end_on: null,
  occurrence_limit: 3,
  expected_due_on_version: 2,
  confirm_start_change: true,
  previous_series_id: null,
});

test("uncertain daily creation keeps the exact operation by task and board actor", () => {
  const ownerStore = new DailyRepetitionOperationStore("owner", "daily-board");
  const collaboratorStore = new DailyRepetitionOperationStore(
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
  const operations = new DailyRepetitionOperationStore("owner", "daily-board");
  const first = command("task-1", "operation-1");
  const second = command("task-2", "operation-2", "2026-11-07");

  operations.set(first);
  operations.set(second);

  assert.deepEqual(operations.get("task-1"), first);
  assert.deepEqual(operations.get("task-2"), second);
  operations.clearAll();
  assert.equal(operations.get("task-1"), null);
  assert.equal(operations.get("task-2"), null);
});
