import assert from "node:assert/strict";
import { test } from "node:test";
import { RepetitionEditOperationStore } from "../../src/lib/daily-repetition-edit-state.ts";

const command = (taskId, operationId) => ({
  operation_id: operationId,
  slug: "repeat-board",
  task_id: taskId,
  expected_revision: 7,
  start_on: "2026-11-05",
  final_mode: "count",
  future_count: 3,
  end_on: null,
  pattern: { frequency: "weekly", interval: 1, weekdays: [4] },
  advance_days: 1,
  appearance_column_id: "column-next",
  template: {
    title: "Review",
    description: "Weekly review",
    priority: "high",
    assignee_id: null,
    steps: [
      {
        id: "template-step-1",
        text: "Review the checklist item",
        is_completed: false,
        position: 0,
        version: 1,
      },
    ],
  },
  confirm_date_choice: false,
});

test("an uncertain edit keeps its exact command for retry and isolates task and actor", () => {
  const ownerStore = new RepetitionEditOperationStore("owner", "repeat-board");
  const otherActor = new RepetitionEditOperationStore("member", "repeat-board");
  const pending = command("task-1", "edit-op-1");

  ownerStore.set(pending);

  assert.deepEqual(ownerStore.get("task-1"), pending);
  assert.equal(ownerStore.get("task-2"), null);
  assert.equal(otherActor.get("task-1"), null);
  assert.equal(ownerStore.clear("task-1"), pending);
  assert.equal(ownerStore.get("task-1"), null);
});

test("separate edits remain retryable and clearing one leaves the other intact", () => {
  const operations = new RepetitionEditOperationStore("owner", "repeat-board");
  const first = command("task-1", "edit-op-1");
  const second = command("task-2", "edit-op-2");
  second.expected_revision = 12;
  second.future_count = 5;

  operations.set(first);
  operations.set(second);

  assert.deepEqual(operations.get("task-1"), first);
  assert.deepEqual(operations.get("task-2"), second);
  operations.clear("task-1");
  assert.equal(operations.get("task-1"), null);
  assert.deepEqual(operations.get("task-2"), second);
  operations.clearAll();
  assert.equal(operations.get("task-2"), null);
});
