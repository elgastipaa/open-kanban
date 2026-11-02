import assert from "node:assert/strict";
import { test } from "node:test";
import { parseUnifiedSearchRequest } from "../../src/lib/unified-search-request.ts";

const boardId = "33000000-0000-4000-8000-000000000001";
const labelId = "33000000-0000-4000-8000-000000000002";
const taskId = "33000000-0000-4000-8000-000000000003";

function request(overrides = {}) {
  return {
    query: "tarea",
    scope: "all",
    includeCompleted: false,
    includeHistory: false,
    unassigned: false,
    labelFilters: [],
    order: "due",
    mode: "suggestions",
    ...overrides,
  };
}

test("parses only the search command fields needed by the RPC", () => {
  assert.deepEqual(
    parseUnifiedSearchRequest(
      request({
        scope: "board",
        boardSlug: "proyecto-a",
        labelFilters: [{ board_id: boardId, label_id: labelId }],
      }),
    ),
    {
      query: "tarea",
      scope: "board",
      boardSlug: "proyecto-a",
      filterBoardId: null,
      includeCompleted: false,
      includeHistory: false,
      priority: null,
      assigneeId: null,
      unassigned: false,
      dueFilter: null,
      labelFilters: [{ board_id: boardId, label_id: labelId }],
      order: "due",
      mode: "suggestions",
      cursor: null,
    },
  );
});

test("rejects invalid scope, oversized query, foreign-shaped labels and stale cursor input", () => {
  assert.equal(parseUnifiedSearchRequest(request({ scope: "board" })), null);
  assert.equal(
    parseUnifiedSearchRequest(request({ query: "x".repeat(201) })),
    null,
  );
  assert.equal(
    parseUnifiedSearchRequest(
      request({
        labelFilters: [
          { board_id: boardId, label_id: labelId, name: "hidden" },
        ],
      }),
    ),
    null,
  );
  assert.equal(
    parseUnifiedSearchRequest(
      request({ cursor: { created_at: "2026-11-01T00:00:00Z", id: taskId } }),
    ),
    null,
  );
});

test("accepts only a well-shaped task cursor and drops unrecognized request keys by rejection", () => {
  assert.notEqual(
    parseUnifiedSearchRequest(
      request({
        mode: "tasks",
        cursor: {
          created_at: "2026-11-01T00:00:00Z",
          id: taskId,
          due_on: null,
        },
      }),
    ),
    null,
  );
  assert.equal(
    parseUnifiedSearchRequest(request({ token: "not-accepted" })),
    null,
  );
  assert.equal(
    parseUnifiedSearchRequest(
      request({
        mode: "tasks",
        cursor: { created_at: "bad", id: taskId, due_on: null },
      }),
    ),
    null,
  );
});
