import assert from "node:assert/strict";
import { test } from "node:test";
import {
  captureTaskFocusOrigin,
  selectTaskFocusTarget,
} from "../../src/lib/task-edit-focus.ts";

const origin = {
  taskId: "task-origin",
  columnId: "column-origin",
  position: 2,
  columnTitle: "Origen",
};

test("origin snapshot retains its column title and position", () => {
  assert.deepEqual(
    captureTaskFocusOrigin("task-origin", "fallback-column", [
      { id: "other-column", title: "Otra", taskIds: ["task-moved"] },
      {
        id: "column-origin",
        title: "En curso",
        taskIds: ["before", "task-origin", "after"],
      },
    ]),
    {
      taskId: "task-origin",
      columnId: "column-origin",
      position: 1,
      columnTitle: "En curso",
    },
  );
});

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
  assert.deepEqual(
    selectTaskFocusTarget(
      origin,
      [{ taskId: "task-moved", columnId: "other-column", position: 2 }],
      ["column-origin", "other-column"],
      true,
    ),
    { kind: "column", columnId: "column-origin" },
  );
  assert.deepEqual(selectTaskFocusTarget(origin, [], [], true), {
    kind: "board",
  });
});

test("equidistant neighbors choose the lower original-column position", () => {
  assert.deepEqual(
    selectTaskFocusTarget(
      origin,
      [
        { taskId: "task-after", columnId: "column-origin", position: 3 },
        { taskId: "task-before", columnId: "column-origin", position: 1 },
      ],
      ["column-origin"],
      true,
    ),
    { kind: "task", taskId: "task-before", columnId: "column-origin" },
  );
});
