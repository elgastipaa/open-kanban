import assert from "node:assert/strict";
import { test } from "node:test";
import {
  changeTaskEditDraft,
  createTaskEditWorkflow,
  failTaskEditSave,
  requireTaskEditReconciliation,
  retryTaskEditSave,
  startTaskEditSave,
  taskEditSaveFollowUp,
  taskMoveFollowUp,
} from "../../src/lib/task-edit-workflow.ts";

const initialDraft = {
  title: "Texto inicial",
  description: "",
  priority: "medium",
  due_on: "",
};

const pendingOperation = {
  id: "40000000-0000-4000-8000-000000000001",
  operation_id: "e8888888-0000-4000-8000-000000000007",
  updates: { title: "Texto pendiente" },
  expected_versions: { title: 1 },
};

test("a network failure keeps the draft and requires an explicit retry", () => {
  const editing = changeTaskEditDraft(createTaskEditWorkflow(initialDraft), {
    ...initialDraft,
    title: "Texto pendiente",
  });
  const sending = startTaskEditSave(editing, pendingOperation);
  const failed = failTaskEditSave(sending, "No se pudo confirmar el guardado.");

  assert.equal(failed.status, "error");
  assert.equal(failed.error, "No se pudo confirmar el guardado.");
  assert.equal(failed.draft.title, "Texto pendiente");
  assert.deepEqual(failed.operation, pendingOperation);

  const retry = retryTaskEditSave(failed);
  assert.deepEqual(retry, {
    state: { ...failed, status: "saving", error: null },
    operation: pendingOperation,
  });
  assert.equal(retryTaskEditSave(retry.state), null);
});

test("an expired operation cannot be replayed until current values are reviewed", () => {
  const editing = changeTaskEditDraft(createTaskEditWorkflow(initialDraft), {
    ...initialDraft,
    title: "Texto pendiente",
  });
  const sending = startTaskEditSave(editing, pendingOperation);
  const expired = requireTaskEditReconciliation(
    sending,
    "Revisa los valores actuales antes de volver a guardar.",
  );

  assert.equal(expired.status, "error");
  assert.equal(expired.draft.title, "Texto pendiente");
  assert.equal(expired.operation, null);
  assert.equal(retryTaskEditSave(expired), null);
});

test("changing a draft after an uncertain save starts a new intent", () => {
  const editing = changeTaskEditDraft(createTaskEditWorkflow(initialDraft), {
    ...initialDraft,
    title: "Texto pendiente",
  });
  const sending = startTaskEditSave(editing, pendingOperation);
  const failed = failTaskEditSave(sending, "Sin conexión.");
  const changed = changeTaskEditDraft(failed, {
    ...failed.draft,
    title: "Texto corregido",
  });

  assert.equal(changed.status, "idle");
  assert.equal(changed.operation, null);
  assert.equal(changed.draft.title, "Texto corregido");
  assert.equal(retryTaskEditSave(changed), null);
});

test("a date-only change is kept as an independent editable field", () => {
  const editing = changeTaskEditDraft(createTaskEditWorkflow(initialDraft), {
    ...initialDraft,
    due_on: "2026-10-31",
  });

  assert.equal(editing.status, "idle");
  assert.equal(editing.draft.title, initialDraft.title);
  assert.equal(editing.draft.due_on, "2026-10-31");
  assert.equal(editing.operation, null);
});

test("delete confirmation follows only a confirmed save", () => {
  assert.equal(taskEditSaveFollowUp("delete", "confirmed"), "confirm-delete");
  assert.equal(taskEditSaveFollowUp("delete", "conflict"), "none");
  assert.equal(taskEditSaveFollowUp("delete", "error"), "none");
  assert.equal(taskEditSaveFollowUp("delete", "reconciliation"), "none");
  assert.equal(taskEditSaveFollowUp("close", "confirmed"), "close");
  assert.equal(taskEditSaveFollowUp("stay", "confirmed"), "none");
});

test("a move follows only a confirmed save or an explicit discard", () => {
  assert.equal(taskMoveFollowUp("save", "confirmed"), "move");
  assert.equal(taskMoveFollowUp("save", "conflict"), "none");
  assert.equal(taskMoveFollowUp("save", "error"), "none");
  assert.equal(taskMoveFollowUp("save", "reconciliation"), "none");
  assert.equal(taskMoveFollowUp("discard"), "move");
  assert.equal(taskMoveFollowUp("cancel"), "none");
});
