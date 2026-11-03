import assert from "node:assert/strict";
import { test } from "node:test";
import {
  getOrCreateTaskChecklistAddCommand,
  getTaskChecklistCompletionReview,
  getTaskChecklistProgress,
  moveTaskChecklistStep,
  settleTaskChecklistAddCommand,
  settleTaskChecklistAddOperation,
  shouldClearTaskChecklistAddText,
  TaskChecklistAddOperationStore,
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

test("an uncertain add replays the same command before accepting another step", async () => {
  const steps = [];
  const receipts = new Map();
  const pendingOperations = new TaskChecklistAddOperationStore(
    "actor-1",
    "board-1",
  );
  let loseFirstResponse = true;

  async function mutateChecklist(command) {
    const existing = receipts.get(command.operation_id);
    if (existing) return existing;

    const receipt = {
      status: "confirmed",
      operation_id: command.operation_id,
      step_id: `step-${steps.length + 1}`,
    };
    receipts.set(command.operation_id, receipt);
    steps.push(command.command.text);
    if (loseFirstResponse) {
      loseFirstResponse = false;
      throw new Error("committed, but the response was lost");
    }
    return receipt;
  }

  let pending = getOrCreateTaskChecklistAddCommand(
    pendingOperations.get("task-1"),
    "task-1",
    "Preparar publicación",
    "operation-1",
  );
  pendingOperations.set(pending);
  await assert.rejects(mutateChecklist(pending));
  pending = settleTaskChecklistAddCommand(pending, "unresolved");
  if (pending) pendingOperations.set(pending);

  // The BoardWorkspace store survives the TaskModal closing and reopening.
  const reopenedCommand = pendingOperations.get("task-1");
  assert.deepEqual(reopenedCommand, pending);
  const attemptedNewAdd = getOrCreateTaskChecklistAddCommand(
    reopenedCommand,
    "task-1",
    "Enviar publicación",
    "operation-2",
  );
  assert.deepEqual(attemptedNewAdd, {
    id: "task-1",
    operation_id: "operation-1",
    command: { action: "add", text: "Preparar publicación" },
  });

  const replayReceipt = await mutateChecklist(attemptedNewAdd);
  assert.equal(replayReceipt.operation_id, "operation-1");
  assert.equal(replayReceipt.step_id, "step-1");
  pending = settleTaskChecklistAddOperation(
    pendingOperations,
    pending,
    replayReceipt.status,
  );
  assert.equal(pending, null);
  assert.equal(pendingOperations.get("task-1"), null);
  assert.deepEqual(steps, ["Preparar publicación"]);
});

test("pending adds stay scoped to an actor and are cleared on access loss", () => {
  const operations = new TaskChecklistAddOperationStore("actor-1", "board-1");
  const firstTask = getOrCreateTaskChecklistAddCommand(
    null,
    "task-1",
    "Paso privado uno",
    "operation-1",
  );
  const secondTask = getOrCreateTaskChecklistAddCommand(
    null,
    "task-2",
    "Paso privado dos",
    "operation-2",
  );
  operations.set(firstTask);
  operations.set(secondTask);

  assert.deepEqual(operations.get("task-1"), firstTask);
  assert.deepEqual(operations.get("task-2"), secondTask);
  assert.equal(
    new TaskChecklistAddOperationStore("actor-2", "board-1").get("task-1"),
    null,
  );
  assert.equal(
    new TaskChecklistAddOperationStore("actor-1", "board-2").get("task-1"),
    null,
  );
  assert.equal(
    new TaskChecklistAddOperationStore("actor-1", "board-1").get("task-1"),
    null,
    "a new workspace starts without the previous session's command",
  );

  const afterAccessLost = settleTaskChecklistAddOperation(
    operations,
    firstTask,
    "access_lost",
  );
  assert.equal(afterAccessLost, null);
  assert.equal(operations.get("task-1"), null);
  assert.equal(operations.get("task-2"), null);
  assert.equal(shouldClearTaskChecklistAddText("access_lost"), true);
  assert.equal(shouldClearTaskChecklistAddText("unresolved"), false);
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
