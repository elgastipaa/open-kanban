import assert from "node:assert/strict";
import { test } from "node:test";
import {
  createRepetitionSeriesDeletionCommand,
  getRepetitionSeriesDeletionConfirmation,
  getRepetitionSeriesRestoreAction,
} from "../../src/lib/repetition-series-recovery-state.ts";

const boardId = "28000000-0000-4000-8000-000000000001";
const seriesId = "28000000-0000-4000-8000-000000000002";
const columnId = "28000000-0000-4000-8000-000000000003";
const destinationId = "28000000-0000-4000-8000-000000000004";

const preview = (overrides = {}) => ({
  status: "available",
  series_id: seriesId,
  board_id: boardId,
  state: "active",
  revision: 4,
  title: "Revisar los reportes",
  occurrence_count: 9,
  task_count: 1,
  requires_confirmation: true,
  retention_hours: 168,
  ...overrides,
});

const deletedSeries = (overrides = {}) => ({
  series_id: seriesId,
  deleted_at: "2026-11-02T12:00:00.000Z",
  expires_at: "2026-11-09T12:00:00.000Z",
  eligibility_checked_at: "2026-11-02T12:00:00.000Z",
  can_restore: true,
  generation_available: true,
  appearance_column_available: true,
  child_columns_available: true,
  ...overrides,
});

test("series deletion requires a fresh explicit history confirmation", () => {
  assert.deepEqual(
    createRepetitionSeriesDeletionCommand(preview(), {
      operationId: "28000000-0000-4000-8000-000000000005",
      slug: "private-board",
      seriesId,
      expectedRevision: 4,
    }),
    {
      operation_id: "28000000-0000-4000-8000-000000000005",
      slug: "private-board",
      series_id: seriesId,
      expected_revision: 4,
      confirm_history: true,
    },
  );
  assert.equal(
    createRepetitionSeriesDeletionCommand(preview({ revision: 3 }), {
      operationId: "28000000-0000-4000-8000-000000000005",
      slug: "private-board",
      seriesId,
      expectedRevision: 4,
    }),
    null,
  );
  assert.equal(
    createRepetitionSeriesDeletionCommand(
      preview({ requires_confirmation: false }),
      {
        operationId: "28000000-0000-4000-8000-000000000005",
        slug: "private-board",
        seriesId,
        expectedRevision: 4,
      },
    ),
    null,
  );
});

test("series deletion confirmation names the whole history and exact retention", () => {
  const text = getRepetitionSeriesDeletionConfirmation(preview());
  assert.match(text, /Revisar los reportes/);
  assert.match(text, /9 ocurrencias/);
  assert.match(text, /1 tarjeta de la serie/);
  assert.match(text, /siete días/);
  assert.match(text, /eliminadas por separado/);
});

test("series recovery can choose a current appearance column when the old one vanished", () => {
  const item = deletedSeries({ appearance_column_available: false });
  assert.deepEqual(
    getRepetitionSeriesRestoreAction(
      item,
      [columnId, destinationId],
      null,
      100,
      200,
    ),
    { status: "needs_destination", targetColumnId: null },
  );
  assert.deepEqual(
    getRepetitionSeriesRestoreAction(
      item,
      [columnId, destinationId],
      destinationId,
      100,
      200,
    ),
    { status: "restore", targetColumnId: destinationId },
  );
  assert.deepEqual(
    getRepetitionSeriesRestoreAction(
      item,
      [columnId, destinationId],
      "deleted-column",
      100,
      200,
    ),
    { status: "needs_destination", targetColumnId: null },
  );
});

test("series recovery expires against the monotonic time of its fresh eligibility", () => {
  const item = deletedSeries();
  assert.deepEqual(
    getRepetitionSeriesRestoreAction(item, [columnId], null, 100, 101),
    { status: "restore", targetColumnId: null },
  );
  const expiry = 100 + 7 * 24 * 60 * 60 * 1000;
  assert.deepEqual(
    getRepetitionSeriesRestoreAction(item, [columnId], null, 100, expiry),
    { status: "expired", targetColumnId: null },
  );
});

test("series recovery requires a valid parent generation and child destinations", () => {
  const item = deletedSeries({ child_columns_available: false });
  assert.deepEqual(
    getRepetitionSeriesRestoreAction(item, [columnId], null, 100, 200),
    { status: "unavailable", targetColumnId: null },
  );
});
