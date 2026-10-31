import assert from "node:assert/strict";
import { test } from "node:test";
import {
  mergeAuthoritativeOrderVersions,
  prepareTaskOrderMove,
} from "../../src/lib/task-order.ts";

function task(id, column_id, position, title = id) {
  return {
    id,
    column_id,
    position,
    title,
    description: `Descripción ${id}`,
    priority: "high",
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
    field_versions: { title: 2, description: 3, priority: 1 },
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

test("an intra-column move records deterministic neighbors and order version only", () => {
  const columns = [
    column(
      "source",
      [task("a", "source", 0), task("b", "source", 1), task("c", "source", 2)],
      7,
    ),
  ];
  const original = structuredClone(columns);

  const plan = prepareTaskOrderMove(columns, "source", "source", 2, 0, "op-up");

  assert.deepEqual(plan.command, {
    operation_id: "op-up",
    moves: [
      {
        id: "c",
        source_column_id: "source",
        column_id: "source",
        before_task_id: null,
        after_task_id: "a",
      },
    ],
    expected_order_versions: { source: 7 },
  });
  assert.deepEqual(
    plan.optimisticUpdates.map(({ id, position }) => [id, position]),
    [
      ["c", 0],
      ["a", 1],
      ["b", 2],
    ],
  );
  assert.deepEqual(columns, original);
  assert.equal("title" in plan.command.moves[0], false);
  assert.equal("field_versions" in plan.optimisticUpdates[0], false);
});

test("a cross-column move uses one-board neighbor anchors and both order versions", () => {
  const columns = [
    column("source", [task("move", "source", 0), task("stay", "source", 1)], 4),
    column(
      "destination",
      [task("before", "destination", 0), task("after", "destination", 1)],
      9,
    ),
  ];

  const plan = prepareTaskOrderMove(
    columns,
    "source",
    "destination",
    0,
    1,
    "op-cross",
  );

  assert.deepEqual(plan.command.moves, [
    {
      id: "move",
      source_column_id: "source",
      column_id: "destination",
      before_task_id: "before",
      after_task_id: "after",
    },
  ]);
  assert.deepEqual(plan.command.expected_order_versions, {
    source: 4,
    destination: 9,
  });
  assert.deepEqual(
    plan.optimisticUpdates.map(({ id, column_id, position }) => [
      id,
      column_id,
      position,
    ]),
    [
      ["stay", "source", 0],
      ["before", "destination", 0],
      ["move", "destination", 1],
      ["after", "destination", 2],
    ],
  );
});

test("moving to an empty column sends explicit null anchors", () => {
  const columns = [
    column("source", [task("move", "source", 0)], 2),
    column("empty", [], 1),
  ];
  const plan = prepareTaskOrderMove(
    columns,
    "source",
    "empty",
    0,
    0,
    "op-empty",
  );

  assert.deepEqual(plan.command.moves[0], {
    id: "move",
    source_column_id: "source",
    column_id: "empty",
    before_task_id: null,
    after_task_id: null,
  });
  assert.deepEqual(plan.command.expected_order_versions, {
    source: 2,
    empty: 1,
  });
});

test("confirmed task inserts and deletes adopt server order versions without guessing increments", () => {
  const local = [
    column("source", [task("kept", "source", 0)], 8),
    column("destination", [], 3),
  ];
  const authorized = [column("source", [], 10), column("destination", [], 3)];

  const reconciled = mergeAuthoritativeOrderVersions(local, authorized);

  assert.deepEqual(
    reconciled.map(({ id, task_order_version }) => [id, task_order_version]),
    [
      ["source", 10],
      ["destination", 3],
    ],
  );
  assert.deepEqual(reconciled[0].tasks, local[0].tasks);
  assert.equal(
    mergeAuthoritativeOrderVersions(reconciled, authorized)[0]
      .task_order_version,
    10,
  );
  assert.equal(
    mergeAuthoritativeOrderVersions(
      [column("source", [], 11)],
      [column("source", [], 10)],
    )[0].task_order_version,
    11,
  );
});

test("a missing task or destination cannot produce a movement command", () => {
  const columns = [column("source", [task("move", "source", 0)], 2)];
  assert.equal(
    prepareTaskOrderMove(columns, "source", "missing", 0, 0, "op"),
    null,
  );
  assert.equal(
    prepareTaskOrderMove(columns, "source", "source", 1, 0, "op"),
    null,
  );
});
