import assert from "node:assert/strict";
import test from "node:test";
import {
  closeColumnDeletionDialog,
  columnDeletionDecision,
  columnDeletionErrorMessage,
  columnDeletionNoDestinationMessage,
  createColumnDeletionCommand,
  failColumnDeletionPreview,
  failColumnDeletionSubmission,
  getColumnDeletionCommand,
  resolveColumnDeletionPreview,
  startColumnDeletionPreview,
  startColumnDeletionSubmission,
} from "../../src/lib/column-deletion-flow.ts";

const preview = {
  status: "preview",
  column_id: "source",
  column_title: "Por hacer",
  task_count: 2,
  task_order_version: 7,
  destinations: [
    { id: "destination", title: "En curso", position: 1 },
    { id: "other", title: "Listo", position: 2 },
  ],
};

test("a populated column requires a destination offered by its preview", () => {
  assert.equal(columnDeletionDecision(preview, null), "needs_destination");
  assert.equal(
    columnDeletionDecision(preview, "foreign"),
    "invalid_destination",
  );
  assert.equal(columnDeletionDecision(preview, "destination"), "ready");
});

test("an empty column can be removed without a destination", () => {
  assert.equal(
    columnDeletionDecision({ ...preview, task_count: 0 }, null),
    "ready",
  );
});

test("the last empty column explains that another column must be added first", () => {
  const lastColumn = { ...preview, task_count: 0, destinations: [] };
  assert.equal(columnDeletionDecision(lastColumn, null), "no_destination");
  assert.equal(
    createColumnDeletionCommand(lastColumn, null, "operation-last"),
    null,
  );
});

test("the last populated column asks for a new destination before moving tasks", () => {
  const lastColumn = { ...preview, destinations: [] };
  assert.equal(columnDeletionDecision(lastColumn, null), "no_destination");
  assert.equal(
    createColumnDeletionCommand(lastColumn, null, "operation-last"),
    null,
  );
});

test("no destination copy distinguishes an empty last column from tasks to move", () => {
  assert.equal(
    columnDeletionNoDestinationMessage(0),
    "No se puede borrar la última columna. Agrega otra columna o cancela para dejar esta columna.",
  );
  assert.equal(
    columnDeletionNoDestinationMessage(2),
    "No se puede borrar la última columna. Agrega otra columna para trasladar allí las tareas o cancela para dejar esta columna.",
  );
});

test("a deletion command carries the preview version and selected destination", () => {
  assert.deepEqual(
    createColumnDeletionCommand(preview, "destination", "operation-1"),
    {
      operation_id: "operation-1",
      column_id: "source",
      destination_column_id: "destination",
      expected_task_order_version: 7,
    },
  );
  assert.equal(createColumnDeletionCommand(preview, null, "operation-2"), null);
});

test("column deletion errors explain the next safe action in Spanish", () => {
  assert.equal(
    columnDeletionErrorMessage("conflict"),
    "La columna o sus tareas cambiaron. Revisa la vista previa actualizada antes de confirmar.",
  );
  assert.equal(
    columnDeletionErrorMessage("uncertain"),
    "No se pudo confirmar el cambio. Revisa el tablero antes de volver a intentar.",
  );
});

test("preview loading and errors stay cancellable without creating a command", () => {
  const loading = startColumnDeletionPreview("source");
  assert.equal(loading.status, "loading");
  assert.equal(getColumnDeletionCommand(loading, "operation-1"), null);

  const failed = failColumnDeletionPreview(loading);
  assert.equal(failed.status, "preview_error");
  assert.equal(getColumnDeletionCommand(failed, "operation-1"), null);
  assert.equal(closeColumnDeletionDialog(failed).status, "closed");
});

test("preview resolution gates confirmation and carries the selected destination", () => {
  const loading = startColumnDeletionPreview("source");
  const ready = resolveColumnDeletionPreview(loading, preview);
  assert.equal(ready.status, "ready");
  assert.equal(getColumnDeletionCommand(ready, "operation-1"), null);

  const selected = { ...ready, destination_column_id: "destination" };
  assert.deepEqual(getColumnDeletionCommand(selected, "operation-1"), {
    operation_id: "operation-1",
    column_id: "source",
    destination_column_id: "destination",
    expected_task_order_version: 7,
  });
});

test("uncertain submission preserves the same command for an idempotent retry", () => {
  const ready = resolveColumnDeletionPreview(
    startColumnDeletionPreview("source"),
    preview,
  );
  const selected = { ...ready, destination_column_id: "destination" };
  const submission = startColumnDeletionSubmission(selected, "operation-1");
  assert.equal(submission.state.status, "submitting");
  assert.deepEqual(submission.command, {
    operation_id: "operation-1",
    column_id: "source",
    destination_column_id: "destination",
    expected_task_order_version: 7,
  });

  const retryable = failColumnDeletionSubmission(submission.state, "uncertain");
  assert.equal(retryable.status, "submit_error");
  assert.deepEqual(getColumnDeletionCommand(retryable, "ignored"), {
    ...submission.command,
  });
});
