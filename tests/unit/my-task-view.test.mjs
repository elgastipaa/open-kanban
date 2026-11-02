import assert from "node:assert/strict";
import test from "node:test";
import { orderMyTaskEntries } from "../../src/lib/my-task-view.ts";

const entry = (
  id,
  { completed = false, due = null, created, completedAt = null },
) => ({
  task: {
    id,
    is_completed: completed,
    due_on: due,
    created_at: created,
    completed_at: completedAt,
  },
});

test("My Tasks preferences preserve active/completed groups and stable date order", () => {
  const tasks = [
    entry("created-first", {
      due: "2026-11-06",
      created: "2026-10-29T00:00:00Z",
    }),
    entry("due-first", { due: "2026-11-04", created: "2026-10-31T00:00:00Z" }),
    entry("late-created", {
      due: "2026-11-05",
      created: "2026-11-01T00:00:00Z",
    }),
    entry("no-date", { due: null, created: "2026-11-02T00:00:00Z" }),
    entry("early-created", {
      due: "2026-11-05",
      created: "2026-10-30T00:00:00Z",
    }),
    entry("completed-old", {
      completed: true,
      due: "2026-11-01",
      created: "2026-10-28T00:00:00Z",
      completedAt: "2026-10-30T00:00:00Z",
    }),
    entry("completed-new", {
      completed: true,
      due: "2026-11-20",
      created: "2026-10-29T00:00:00Z",
      completedAt: "2026-11-01T00:00:00Z",
    }),
  ];

  assert.deepEqual(
    orderMyTaskEntries(tasks, "due").map(({ task }) => task.id),
    [
      "due-first",
      "early-created",
      "late-created",
      "created-first",
      "no-date",
      "completed-new",
      "completed-old",
    ],
  );
  assert.deepEqual(
    orderMyTaskEntries(tasks, "created").map(({ task }) => task.id),
    [
      "created-first",
      "early-created",
      "due-first",
      "late-created",
      "no-date",
      "completed-new",
      "completed-old",
    ],
  );
});
