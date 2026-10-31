import assert from "node:assert/strict";
import { test } from "node:test";
import {
  cancelTaskDelete,
  confirmTaskDelete,
  createTaskDeleteFlow,
  finishTaskDeleteDialogClose,
  finishTaskEditorClose,
  requestCardTaskDelete,
  requestEditorTaskDelete,
} from "../../src/lib/task-delete-flow.ts";
import { selectTaskFocusTarget } from "../../src/lib/task-edit-focus.ts";

test("editor delete waits for the editor to close before opening confirmation", () => {
  const pending = requestEditorTaskDelete(createTaskDeleteFlow(), "task-1");
  assert.deepEqual(pending, {
    deletingTaskId: null,
    waitingForEditorCloseTaskId: "task-1",
    resumeEditorTaskId: "task-1",
    restoreFocusAfterDialogClose: false,
  });

  const confirmed = finishTaskEditorClose(pending);
  assert.deepEqual(confirmed, {
    deletingTaskId: "task-1",
    waitingForEditorCloseTaskId: null,
    resumeEditorTaskId: "task-1",
    restoreFocusAfterDialogClose: false,
  });
});

test("cancel reopens only the saved editor when its task still exists", () => {
  const flow = finishTaskEditorClose(
    requestEditorTaskDelete(createTaskDeleteFlow(), "task-1"),
  );

  assert.deepEqual(cancelTaskDelete(flow, true), {
    flow: createTaskDeleteFlow(),
    reopenEditorTaskId: "task-1",
  });
  assert.deepEqual(cancelTaskDelete(flow, false), {
    flow: createTaskDeleteFlow(),
    reopenEditorTaskId: null,
  });
});

test("card delete opens directly and never schedules editor restoration", () => {
  const flow = requestCardTaskDelete(createTaskDeleteFlow(), "task-2");
  assert.deepEqual(flow, {
    deletingTaskId: "task-2",
    waitingForEditorCloseTaskId: null,
    resumeEditorTaskId: null,
    restoreFocusAfterDialogClose: false,
  });
  assert.deepEqual(cancelTaskDelete(flow, true), {
    flow: createTaskDeleteFlow(),
    reopenEditorTaskId: null,
  });
  assert.deepEqual(confirmTaskDelete(flow), createTaskDeleteFlow());
});

test("only confirmed editor deletes restore focus after the dialog closes", () => {
  const origin = {
    taskId: "task-1",
    columnId: "column-origin",
    position: 2,
    columnTitle: "En curso",
  };
  const candidates = [
    { taskId: "neighbor", columnId: "column-origin", position: 2 },
  ];
  const editorDelete = finishTaskEditorClose(
    requestEditorTaskDelete(createTaskDeleteFlow(), "task-1"),
  );
  const confirmedEditorDelete = confirmTaskDelete(editorDelete);
  const editorDialogClose = finishTaskDeleteDialogClose(confirmedEditorDelete);
  assert.deepEqual(editorDialogClose, {
    flow: createTaskDeleteFlow(),
    restoreTaskFocus: true,
  });
  assert.deepEqual(
    editorDialogClose.restoreTaskFocus
      ? selectTaskFocusTarget(origin, candidates, ["column-origin"], true)
      : null,
    { kind: "task", taskId: "neighbor", columnId: "column-origin" },
  );

  const cardDelete = confirmTaskDelete(
    requestCardTaskDelete(createTaskDeleteFlow(), "task-2"),
  );
  const cardDialogClose = finishTaskDeleteDialogClose(cardDelete);
  assert.deepEqual(cardDialogClose, {
    flow: createTaskDeleteFlow(),
    restoreTaskFocus: false,
  });
  assert.equal(
    cardDialogClose.restoreTaskFocus
      ? selectTaskFocusTarget(origin, candidates, ["column-origin"], true)
      : null,
    null,
  );
});
