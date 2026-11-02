import assert from "node:assert/strict";
import { test } from "node:test";
import { TaskMutationLedger } from "../../src/hooks/use-board/task-mutation-ledger.ts";
import { reconcileAuthorizedTaskOrder } from "../../src/hooks/use-board/task-order-reconciliation.ts";
import { prepareTaskOrderMove } from "../../src/lib/task-order.ts";

function task(id, column_id, position, title = id) {
  return {
    id,
    column_id,
    position,
    title,
    description: null,
    priority: "medium",
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
    field_versions: { title: 1, description: 1, priority: 1 },
  };
}

function column(id, tasks, task_order_version) {
  return {
    id,
    board_id: "board-1",
    title: id,
    position: 0,
    is_collapsed: false,
    task_order_version,
    created_at: "2026-01-01T00:00:00.000Z",
    tasks,
  };
}

test("a remote reorder read after create/delete replaces old order and preserves pending edits", async () => {
  const localColumns = [
    column(
      "source",
      [task("a", "source", 0, "Tarea A"), task("b", "source", 1, "Tarea B")],
      8,
    ),
    column("destination", [], 3),
  ];
  const ledger = new TaskMutationLedger(localColumns);
  const alreadyIssuedMove = prepareTaskOrderMove(
    localColumns,
    "source",
    "source",
    0,
    1,
    "already-issued",
  );
  ledger.begin(
    {
      id: "pending-edit",
      kind: "edit",
      taskId: "a",
      updates: { title: "Edición pendiente" },
    },
    localColumns,
  );
  let latestColumns = localColumns;
  let accessLostCalls = 0;

  const reconciled = await reconcileAuthorizedTaskOrder({
    readBoard: async () => {
      latestColumns = [
        column(
          "source",
          [
            task("b", "source", 0, "Tarea B"),
            task("a", "source", 1, "Tarea A"),
          ],
          9,
        ),
        column("destination", [], 3),
      ];
      return { columns: latestColumns };
    },
    ledger,
    sessionEpoch: 4,
    getCurrentSessionEpoch: () => 4,
    onAccessLost: () => {
      accessLostCalls += 1;
    },
    isAccessDenied: () => false,
  });

  assert.deepEqual(
    reconciled?.map((currentColumn) => currentColumn.tasks.map(({ id }) => id)),
    [["b", "a"], []],
  );
  assert.equal(reconciled?.[0].task_order_version, 9);
  assert.equal(reconciled?.[0].tasks[1].title, "Edición pendiente");
  assert.deepEqual(alreadyIssuedMove?.command.expected_order_versions, {
    source: 8,
  });
  assert.deepEqual(
    prepareTaskOrderMove(reconciled ?? [], "source", "source", 0, 1, "next")
      ?.command.expected_order_versions,
    { source: 9 },
  );
  assert.equal(accessLostCalls, 0);
});

test("an unresolved delete settles its optimistic intent and restores the task for review", () => {
  const originalTask = task(
    "task-uncertain",
    "source",
    0,
    "Tarea pendiente de confirmar",
  );
  const originalColumns = [column("source", [originalTask], 1)];
  const ledger = new TaskMutationLedger(originalColumns);
  const optimisticColumns = ledger.begin(
    {
      id: "delete-operation",
      kind: "delete",
      taskId: originalTask.id,
    },
    originalColumns,
  );
  assert.deepEqual(optimisticColumns[0].tasks, []);

  const settledColumns = ledger.settle("delete-operation", optimisticColumns);
  const reviewableColumns = ledger.restoreTaskAfterFailedDelete(
    originalTask,
    settledColumns,
  );

  assert.equal(ledger.revision > 0, true);
  assert.deepEqual(
    reviewableColumns[0].tasks.map(({ id }) => id),
    [originalTask.id],
  );
  assert.equal(reviewableColumns[0].tasks[0].title, originalTask.title);
});
