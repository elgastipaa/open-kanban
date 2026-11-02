import assert from "node:assert/strict";
import { test } from "node:test";
import {
  buildSeriesTaskEditorHref,
  resolveSeriesTaskEditorIntent,
} from "../../src/lib/repetition-series-navigation.ts";

const taskId = "27000000-0000-4000-8000-000000000099";
const boardId = "27000000-0000-4000-8000-000000000098";
const cursorCreatedAt = "2026-11-02T04:10:00.000Z";
const cursorId = "27000000-0000-4000-8000-000000000097";
const seriesId = "27000000-0000-4000-8000-000000000096";
const occurrenceId = "27000000-0000-4000-8000-000000000095";
const commentId = "27000000-0000-4000-8000-000000000094";
const historyBeforeOn = "2026-10-26";
const historyBeforeId = "27000000-0000-4000-8000-000000000093";

test("an accessible series opens the existing task editor and returns to its filtered list", () => {
  const href = buildSeriesTaskEditorHref({
    boardSlug: "weekly-board",
    taskId,
    boardId,
    state: "active",
    listCursor: { created_at: cursorCreatedAt, id: cursorId },
    selectedSeriesId: seriesId,
    selectedOccurrenceId: occurrenceId,
    selectedCommentId: commentId,
    historyCursor: {
      occurrence_on: historyBeforeOn,
      id: historyBeforeId,
    },
  });
  const destination = new URL(href, "https://openkanban.invalid");

  assert.equal(destination.origin, "https://openkanban.invalid");
  assert.equal(destination.pathname, "/weekly-board");
  assert.equal(destination.searchParams.get("task"), taskId);
  assert.equal(destination.searchParams.get("edit_repetition"), "1");
  assert.equal(destination.searchParams.get("from"), "series");
  assert.equal(destination.searchParams.get("series_board"), boardId);
  assert.equal(destination.searchParams.get("series_state"), "active");
  assert.equal(destination.searchParams.get("series_selected_id"), seriesId);
  assert.equal(
    destination.searchParams.get("series_selected_occurrence"),
    occurrenceId,
  );
  assert.equal(
    destination.searchParams.get("series_selected_comment"),
    commentId,
  );
  assert.equal(
    destination.searchParams.get("series_before_created_at"),
    cursorCreatedAt,
  );
  assert.equal(destination.searchParams.get("series_before_id"), cursorId);
  assert.equal(
    destination.searchParams.get("series_history_before_on"),
    historyBeforeOn,
  );
  assert.equal(
    destination.searchParams.get("series_history_before_id"),
    historyBeforeId,
  );

  assert.deepEqual(
    resolveSeriesTaskEditorIntent({
      taskId: destination.searchParams.get("task"),
      editRepetition: destination.searchParams.get("edit_repetition"),
      from: destination.searchParams.get("from"),
      seriesBoardId: destination.searchParams.get("series_board"),
      seriesState: destination.searchParams.get("series_state"),
      seriesBeforeCreatedAt: destination.searchParams.get(
        "series_before_created_at",
      ),
      seriesBeforeId: destination.searchParams.get("series_before_id"),
      selectedSeriesId: destination.searchParams.get("series_selected_id"),
      selectedOccurrenceId: destination.searchParams.get(
        "series_selected_occurrence",
      ),
      selectedCommentId: destination.searchParams.get(
        "series_selected_comment",
      ),
      historyBeforeOn: destination.searchParams.get("series_history_before_on"),
      historyBeforeId: destination.searchParams.get("series_history_before_id"),
      authorizedBoardTaskIds: [taskId],
    }),
    {
      taskId,
      returnHref: `/series?board=${boardId}&state=active&series=${seriesId}&occurrence=${occurrenceId}&comment=${commentId}&series_before_created_at=${encodeURIComponent(cursorCreatedAt)}&series_before_id=${cursorId}&history_before_on=${historyBeforeOn}&history_before_id=${historyBeforeId}`,
    },
  );
});

test("the deep link does not authorize a task missing from the current board snapshot", () => {
  assert.equal(
    resolveSeriesTaskEditorIntent({
      taskId,
      editRepetition: "1",
      from: "series",
      seriesBoardId: boardId,
      seriesState: "active",
      seriesBeforeCreatedAt: null,
      seriesBeforeId: null,
      selectedSeriesId: null,
      selectedOccurrenceId: null,
      selectedCommentId: null,
      historyBeforeOn: null,
      historyBeforeId: null,
      authorizedBoardTaskIds: [],
    }),
    null,
  );
});
