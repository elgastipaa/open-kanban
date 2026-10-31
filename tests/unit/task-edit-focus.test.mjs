import assert from "node:assert/strict";
import { test } from "node:test";
import { selectTaskFocusTarget } from "../../src/lib/task-edit-focus.ts";

const origin = {
  taskId: "task-origin",
  columnId: "column-origin",
  position: 2,
};

test("focus restoration prefers the original card, then its nearest neighbor", () => {
  assert.deepEqual(
    selectTaskFocusTarget(
      origin,
      [
        { taskId: "task-near", columnId: "column-origin", position: 3 },
        { taskId: "task-origin", columnId: "column-origin", position: 9 },
        { taskId: "task-far", columnId: "column-origin", position: 0 },
      ],
      ["column-origin"],
      true,
    ),
    { kind: "task", taskId: "task-origin", columnId: "column-origin" },
  );

  assert.deepEqual(
    selectTaskFocusTarget(
      origin,
      [
        { taskId: "task-near", columnId: "column-origin", position: 3 },
        { taskId: "task-far", columnId: "column-origin", position: 0 },
        { taskId: "task-moved", columnId: "other-column", position: 2 },
      ],
      ["column-origin", "other-column"],
      true,
    ),
    { kind: "task", taskId: "task-near", columnId: "column-origin" },
  );
});

test("focus restoration falls back to the original column, then the board", () => {
  assert.deepEqual(selectTaskFocusTarget(origin, [], ["column-origin"], true), {
    kind: "column",
    columnId: "column-origin",
  });
  assert.deepEqual(selectTaskFocusTarget(origin, [], [], true), {
    kind: "board",
  });
});
