import assert from "node:assert/strict";
import { test } from "node:test";
import {
  cancelTaskDelete,
  confirmTaskDelete,
  createTaskDeleteFlow,
  finishTaskEditorClose,
  requestCardTaskDelete,
  requestEditorTaskDelete,
} from "../../src/lib/task-delete-flow.ts";

test("editor delete waits for the editor to close before opening confirmation", () => {
  const pending = requestEditorTaskDelete(createTaskDeleteFlow(), "task-1");
  assert.deepEqual(pending, {
    deletingTaskId: null,
    waitingForEditorCloseTaskId: "task-1",
    resumeEditorTaskId: "task-1",
  });

  const confirmed = finishTaskEditorClose(pending);
  assert.deepEqual(confirmed, {
    deletingTaskId: "task-1",
    waitingForEditorCloseTaskId: null,
    resumeEditorTaskId: "task-1",
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
  });
  assert.deepEqual(cancelTaskDelete(flow, true), {
    flow: createTaskDeleteFlow(),
    reopenEditorTaskId: null,
  });
  assert.deepEqual(confirmTaskDelete(flow), createTaskDeleteFlow());
});
