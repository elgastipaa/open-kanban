import assert from "node:assert/strict";
import test from "node:test";
import {
  isSavedViewDefinition,
  parseSavedViewReferenceFields,
  parseSavedViewsSnapshot,
  resolveSavedViewConflict,
} from "../../src/lib/saved-view-state.ts";

const boardId = "a3500000-0000-4000-8000-000000000001";
const labelId = "a3500000-0000-4000-8000-000000000002";

const searchDefinition = {
  query: "reunión",
  scope: "board",
  boardId,
  includeCompleted: true,
  includeHistory: true,
  filterBoardId: null,
  dueFilter: "next_7_days",
  priority: "high",
  assigneeId: null,
  unassigned: true,
  labels: [{ boardId, labelId }],
  order: "created",
};

const myTasksDefinition = {
  query: "",
  scope: "my_tasks",
  boardId: null,
  includeCompleted: true,
  includeHistory: false,
  filterBoardId: null,
  dueFilter: null,
  priority: null,
  assigneeId: null,
  unassigned: false,
  labels: [],
  order: "due",
};

function savedView(overrides = {}) {
  return {
    id: "b3500000-0000-4000-8000-000000000001",
    context_type: "search",
    name: "Plan de la semana",
    definition: searchDefinition,
    version: 3,
    needs_review: false,
    created_at: "2026-10-01T12:00:00Z",
    updated_at: "2026-10-02T12:00:00Z",
    deleted_at: null,
    ...overrides,
  };
}

test("saved search definition permits independently persisted history and completed flags", () => {
  assert.equal(isSavedViewDefinition("search", searchDefinition), true);
  assert.equal(isSavedViewDefinition("my_tasks", myTasksDefinition), true);
  assert.equal(
    isSavedViewDefinition("search", { ...searchDefinition, unexpected: true }),
    false,
  );
});

test("saved definition rejects context leaks, invalid references, and duplicate label IDs", () => {
  assert.equal(
    isSavedViewDefinition("my_tasks", { ...myTasksDefinition, query: "tarea" }),
    false,
  );
  assert.equal(
    isSavedViewDefinition("search", { ...searchDefinition, boardId: null }),
    false,
  );
  assert.equal(
    isSavedViewDefinition("search", {
      ...searchDefinition,
      labels: [
        { boardId, labelId },
        { boardId: boardId.toUpperCase(), labelId: labelId.toUpperCase() },
      ],
    }),
    false,
  );
  assert.deepEqual(
    parseSavedViewReferenceFields([
      { field: "labels" },
      { field: "boardId" },
      { field: "labels" },
    ]),
    ["labels", "boardId"],
  );
  assert.equal(parseSavedViewReferenceFields([{ field: "privateName" }]), null);
});

test("list parsing keeps active and deleted collections separate and rejects malformed definitions", () => {
  const snapshot = parseSavedViewsSnapshot("search", {
    status: "available",
    context_type: "search",
    active_views: [savedView()],
    deleted_views: [
      savedView({
        id: "b3500000-0000-4000-8000-000000000002",
        deleted_at: "2026-10-03T12:00:00Z",
      }),
    ],
  });
  assert.equal(snapshot.status, "available");
  assert.equal(snapshot.active_views.length, 1);
  assert.equal(snapshot.deleted_views.length, 1);
  assert.equal(
    parseSavedViewsSnapshot("search", {
      status: "available",
      context_type: "search",
      active_views: [savedView({ definition: { query: "private" } })],
      deleted_views: [],
    }).status,
    "error",
  );
});

test("a stale update preserves the local variation until an explicit conflict choice", () => {
  const current = savedView({
    version: 5,
    definition: { ...searchDefinition, query: "guardia" },
  });
  const conflict = {
    current,
    localDefinition: { ...searchDefinition, query: "reunión urgente" },
  };
  assert.deepEqual(resolveSavedViewConflict(conflict, "keep_local"), {
    definition: conflict.localDefinition,
    expectedVersion: 5,
  });
  assert.deepEqual(resolveSavedViewConflict(conflict, "use_current"), {
    definition: current.definition,
    expectedVersion: 5,
  });
  assert.equal(conflict.localDefinition.query, "reunión urgente");
});
