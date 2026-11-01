import assert from "node:assert/strict";
import { test } from "node:test";
import {
  getTaskChecklistCompletionReview,
  getTaskChecklistProgress,
  moveTaskChecklistStep,
} from "../../src/lib/task-checklist-state.ts";

const steps = [
  {
    id: "step-a",
    text: "Revisar",
    is_completed: false,
    position: 0,
    version: 2,
  },
  {
    id: "step-b",
    text: "Guardar",
    is_completed: true,
    position: 1,
    version: 4,
  },
  {
    id: "step-c",
    text: "Compartir",
    is_completed: false,
    position: 2,
    version: 1,
  },
];

test("checklist progress counts completed and pending steps without changing them", () => {
  assert.deepEqual(getTaskChecklistProgress(steps), {
    completedCount: 1,
    totalCount: 3,
    pendingCount: 2,
  });
  assert.deepEqual(
    steps.map((step) => step.position),
    [0, 1, 2],
  );
});

test("accessible step movement updates positions and preserves each step state", () => {
  const moved = moveTaskChecklistStep(steps, "step-c", -2);

  assert.deepEqual(moved, [
    { ...steps[2], position: 0 },
    { ...steps[0], position: 1 },
    { ...steps[1], position: 2 },
  ]);
  assert.deepEqual(
    steps.map((step) => step.id),
    ["step-a", "step-b", "step-c"],
  );
  assert.deepEqual(moveTaskChecklistStep(steps, "step-a", -1), steps);
  assert.deepEqual(moveTaskChecklistStep(steps, "missing", 1), steps);
});

test("completion confirmation uses the server's current count and checklist revision", () => {
  const preview = getTaskChecklistCompletionReview({
    status: "confirmation_required",
    operation_id: "operation-1",
    pending_steps_count: 2,
    checklist_version: 8,
  });
  const refreshedConflict = getTaskChecklistCompletionReview({
    status: "conflict",
    operation_id: "operation-1",
    pending_steps_count: 1,
    checklist_version: 9,
  });

  assert.deepEqual(preview, {
    operationId: "operation-1",
    pendingStepsCount: 2,
    checklistVersion: 8,
  });
  assert.deepEqual(refreshedConflict, {
    operationId: "operation-1",
    pendingStepsCount: 1,
    checklistVersion: 9,
  });
  assert.equal(
    getTaskChecklistCompletionReview({
      status: "conflict",
      operation_id: "operation-2",
      task: {},
    }),
    null,
  );
});
