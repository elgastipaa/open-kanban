import assert from "node:assert/strict";
import test from "node:test";
import {
  acknowledgeTaskCopyPreview,
  canCreateTaskCopy,
  emptyTaskCopyFormState,
  receiveTaskCopyPreview,
} from "../../src/lib/task-copy-state.ts";

function preview(sourceHash, title, targetColumnId, description) {
  return {
    status: "available",
    source_hash: sourceHash,
    title,
    target_column_id: targetColumnId,
    description,
    labels: [],
  };
}

test("changed copyable source content keeps title and destination until reviewed", () => {
  let state = receiveTaskCopyPreview(
    emptyTaskCopyFormState(),
    preview("hash-a", "Título original", "source", "Descripción inicial"),
  );
  state = { ...state, title: "Título elegido", targetColumnId: "destination" };

  const refreshed = receiveTaskCopyPreview(
    state,
    preview("hash-b", "Título actualizado", "source", "Descripción nueva"),
  );

  assert.equal(refreshed.preview.title, "Título actualizado");
  assert.equal(refreshed.preview.description, "Descripción nueva");
  assert.equal(refreshed.title, "Título elegido");
  assert.equal(refreshed.targetColumnId, "destination");
  assert.equal(refreshed.reviewRequired, true);
  assert.equal(canCreateTaskCopy(refreshed), false);
  assert.equal(canCreateTaskCopy(acknowledgeTaskCopyPreview(refreshed)), true);
});

test("a preview refresh with the same copyable hash needs no extra review", () => {
  let state = receiveTaskCopyPreview(
    emptyTaskCopyFormState(),
    preview("same-hash", "Título original", "source", "Descripción"),
  );
  state = { ...state, title: "Título elegido", targetColumnId: "destination" };

  state = receiveTaskCopyPreview(
    state,
    preview("same-hash", "Título original", "source", "Descripción"),
  );

  assert.equal(state.title, "Título elegido");
  assert.equal(state.targetColumnId, "destination");
  assert.equal(state.reviewRequired, false);
  assert.equal(canCreateTaskCopy(state), true);
});
