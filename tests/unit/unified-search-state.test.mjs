import assert from "node:assert/strict";
import { test } from "node:test";
import {
  clearUnifiedSearchFilters,
  isCurrentUnifiedSearchRequest,
} from "../../src/lib/unified-search-state.ts";

test("only the latest query response for the current account may be applied", () => {
  assert.equal(
    isCurrentUnifiedSearchRequest(8, 8, "account-a", "account-a"),
    true,
  );
  assert.equal(
    isCurrentUnifiedSearchRequest(7, 8, "account-a", "account-a"),
    false,
  );
  assert.equal(
    isCurrentUnifiedSearchRequest(8, 8, "account-a", "account-b"),
    false,
  );
});

test("clear restores pending/history defaults while preserving scope and personal order", () => {
  assert.deepEqual(
    clearUnifiedSearchFilters({
      query: "reunión",
      scope: "board",
      boardSlug: "equipo-a",
      filterBoardId: "board-id",
      includeCompleted: true,
      includeHistory: true,
      priority: "urgent",
      assigneeId: "member-id",
      unassigned: false,
      dueFilter: "overdue",
      labelFilters: [{ board_id: "board-id", label_id: "label-id" }],
      order: "created",
      mode: "tasks",
    }),
    {
      query: "",
      scope: "board",
      boardSlug: "equipo-a",
      filterBoardId: null,
      includeCompleted: false,
      includeHistory: false,
      priority: null,
      assigneeId: null,
      unassigned: false,
      dueFilter: null,
      labelFilters: [],
      order: "created",
      mode: "tasks",
    },
  );
});
