import assert from "node:assert/strict";
import test from "node:test";
import {
  beginViewPreferenceChange,
  createViewPreferenceState,
  reconcileViewPreferenceSnapshot,
  resolveViewPreferenceConflict,
  settleViewPreferenceSave,
} from "../../src/lib/view-preference-state.ts";

const searchContext = { type: "search_all", boardId: null };

test("each view context starts from its own agreed defaults", () => {
  const board = createViewPreferenceState("actor-a", {
    type: "board",
    boardId: "board-a",
  });
  const myTasks = createViewPreferenceState("actor-a", {
    type: "my_tasks",
    boardId: null,
  });
  const search = createViewPreferenceState("actor-a", searchContext);
  const boardSearch = createViewPreferenceState("actor-a", {
    type: "search_board",
    boardId: "board-a",
  });

  assert.deepEqual(board.values.labels, []);
  assert.deepEqual(board.values.completed_view, {
    hidden: [],
    collapsed: [],
  });
  assert.equal(myTasks.values.order, "due");
  assert.deepEqual(myTasks.values.completed_view, {
    visible: true,
    expanded: true,
  });
  assert.equal(search.values.order, "due");
  assert.equal(search.values.include_completed, false);
  assert.equal(search.values.include_history, false);
  assert.equal(boardSearch.values.include_history, false);
  assert.notEqual(search.context.type, boardSearch.context.type);
});

test("separate preference settings save at independent versions", () => {
  let state = createViewPreferenceState("actor-a", searchContext);
  state = beginViewPreferenceChange(state, "order", "created");
  state = settleViewPreferenceSave(state, {
    status: "saved",
    preference_key: "order",
    value: "created",
    version: 1,
  });
  state = beginViewPreferenceChange(state, "filter_due", "today");
  state = settleViewPreferenceSave(state, {
    status: "saved",
    preference_key: "filter_due",
    value: "today",
    version: 1,
  });

  assert.equal(state.values.order, "created");
  assert.equal(state.values.filter_due, "today");
  assert.equal(state.versions.order, 1);
  assert.equal(state.versions.filter_due, 1);
  assert.deepEqual(state.conflicts, {});
});

test("a stale save keeps its local choice until an explicit conflict decision", () => {
  let state = createViewPreferenceState("actor-a", searchContext);
  state = beginViewPreferenceChange(state, "order", "created");
  state = settleViewPreferenceSave(state, {
    status: "conflict",
    preference_key: "order",
    value: "due",
    version: 4,
  });

  assert.equal(state.values.order, "created");
  assert.equal(state.versions.order, 0);
  assert.deepEqual(state.conflicts.order, { value: "due", version: 4 });

  const loadSaved = resolveViewPreferenceConflict(state, "order", "load-saved");
  assert.equal(loadSaved.values.order, "due");
  assert.equal(loadSaved.versions.order, 4);
  assert.equal(loadSaved.conflicts.order, undefined);

  const keepLocal = resolveViewPreferenceConflict(state, "order", "keep-local");
  assert.equal(keepLocal.state.values.order, "created");
  assert.equal(keepLocal.state.versions.order, 4);
  assert.deepEqual(keepLocal.command, {
    preference_key: "order",
    value: "created",
    expected_version: 4,
  });
});

test("a rejected stale reference remains visible for explicit repair", () => {
  let state = createViewPreferenceState("actor-a", searchContext);
  state = beginViewPreferenceChange(state, "filter_board", "revoked-board-id");
  state = settleViewPreferenceSave(state, {
    status: "invalid_reference",
    preference_key: "filter_board",
  });

  assert.equal(state.values.filter_board, "revoked-board-id");
  assert.equal(state.errors.filter_board, "invalid_reference");
  assert.equal(state.versions.filter_board, 0);
});

test("authorized refresh merges untouched settings and surfaces same-setting conflicts", () => {
  let state = createViewPreferenceState("actor-a", searchContext, {
    status: "available",
    context_type: "search_all",
    board_id: null,
    preferences: {
      order: { value: "due", version: 2 },
      filter_due: { value: null, version: 1 },
      filter_labels: { value: [], version: 3 },
      filter_board: { value: null, version: 0 },
      filter_priority: { value: null, version: 0 },
      filter_responsibility: {
        value: { assignee_id: null, unassigned: false },
        version: 0,
      },
      include_completed: { value: false, version: 0 },
      include_history: { value: false, version: 0 },
    },
  });
  state = beginViewPreferenceChange(state, "order", "created");

  const refreshed = reconcileViewPreferenceSnapshot(state, {
    status: "available",
    context_type: "search_all",
    board_id: null,
    preferences: {
      order: { value: "due", version: 3 },
      filter_due: { value: "today", version: 2 },
      filter_labels: { value: [], version: 3 },
      filter_board: { value: null, version: 0 },
      filter_priority: { value: null, version: 0 },
      filter_responsibility: {
        value: { assignee_id: null, unassigned: false },
        version: 0,
      },
      include_completed: { value: false, version: 0 },
      include_history: { value: false, version: 0 },
    },
  });

  assert.equal(refreshed.values.order, "created");
  assert.deepEqual(refreshed.conflicts.order, { value: "due", version: 3 });
  assert.equal(refreshed.values.filter_due, "today");
  assert.equal(refreshed.versions.filter_due, 2);
});

test("confirmed access loss clears local preference values", () => {
  let state = createViewPreferenceState("actor-a", searchContext);
  state = beginViewPreferenceChange(state, "order", "created");
  const unavailable = reconcileViewPreferenceSnapshot(state, {
    status: "unavailable",
  });

  assert.equal(unavailable.accountId, null);
  assert.equal(unavailable.accessLost, true);
  assert.equal(unavailable.values.order, "due");
});

test("explicit URL state stays local and requires review against saved settings", () => {
  const state = createViewPreferenceState(
    "actor-a",
    searchContext,
    {
      status: "available",
      context_type: "search_all",
      board_id: null,
      preferences: {
        order: { value: "due", version: 5 },
        filter_due: { value: null, version: 0 },
        filter_labels: { value: [], version: 0 },
        filter_board: { value: null, version: 0 },
        filter_priority: { value: null, version: 0 },
        filter_responsibility: {
          value: { assignee_id: null, unassigned: false },
          version: 0,
        },
        include_completed: { value: false, version: 0 },
        include_history: { value: false, version: 0 },
      },
    },
    { order: "created" },
  );

  assert.equal(state.values.order, "created");
  assert.equal(state.versions.order, 5);
  assert.equal(state.modified.order, true);
  assert.deepEqual(state.conflicts.order, { value: "due", version: 5 });
});
