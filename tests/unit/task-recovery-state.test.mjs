import assert from "node:assert/strict";
import { test } from "node:test";
import {
  formatTaskRecoveryTimestamp,
  getTaskRecoveryExpiryMonotonicTime,
  getTaskRecoveryListViewState,
  getTaskRecoveryRestoreAction,
  isTaskRecoveryRestorableAtMonotonicTime,
  shouldClearTaskRecoveryItems,
  taskRecoveryCauseLabel,
  taskRecoveryDestinationFieldIds,
  taskRecoveryLoadErrorMessage,
  taskRecoveryRestoreErrorMessage,
} from "../../src/lib/task-recovery-state.ts";

test("request latency is conservatively included to avoid post-deadline actions", () => {
  const deadline = {
    can_restore: true,
    expires_at: "2026-11-01T00:00:02.000Z",
    eligibility_checked_at: "2026-10-31T23:59:02.000Z",
  };
  const requestStartedAt = 1_000;
  const eligibilityCheckedAtMonotonic = 3_000;
  const eligibilityResponseReceivedAt = 5_000;

  assert.ok(eligibilityCheckedAtMonotonic > requestStartedAt);
  assert.ok(eligibilityResponseReceivedAt > eligibilityCheckedAtMonotonic);
  const expiryMonotonicTime = getTaskRecoveryExpiryMonotonicTime(
    deadline,
    requestStartedAt,
  );
  assert.equal(
    expiryMonotonicTime,
    requestStartedAt + 60_000,
    "server-to-browser latency is conservatively included in the UI deadline",
  );
  assert.equal(
    isTaskRecoveryRestorableAtMonotonicTime(
      deadline,
      requestStartedAt,
      requestStartedAt + 59_999,
      true,
    ),
    true,
  );
  assert.equal(
    isTaskRecoveryRestorableAtMonotonicTime(
      deadline,
      requestStartedAt,
      requestStartedAt + 60_000,
      true,
    ),
    false,
    "using request start may hide restore early, but must never offer it after the server deadline",
  );
  assert.equal(
    isTaskRecoveryRestorableAtMonotonicTime(
      deadline,
      requestStartedAt,
      eligibilityCheckedAtMonotonic + 60_000,
      true,
    ),
    false,
    "restore must already be hidden at the database deadline despite response latency",
  );
});

test("stale eligibility cannot authorize recovery while a refresh is pending", () => {
  const deadline = {
    can_restore: true,
    expires_at: "2026-11-01T00:00:00.000Z",
    eligibility_checked_at: "2026-10-31T23:59:00.000Z",
  };

  assert.equal(
    isTaskRecoveryRestorableAtMonotonicTime(deadline, 5_000, 5_100, false),
    false,
  );
});

test("recovery destination label and select use unique, associated IDs", () => {
  const ids = taskRecoveryDestinationFieldIds("task-123");

  assert.notEqual(ids.labelId, ids.selectId);
  assert.equal(ids.htmlFor, ids.selectId);
});

test("recovery list maps loading, failure, empty, and ready states distinctly", () => {
  assert.equal(
    getTaskRecoveryListViewState({
      isLoading: true,
      hasError: false,
      itemCount: 0,
      hasCurrentEligibility: false,
    }),
    "loading",
  );
  assert.equal(
    getTaskRecoveryListViewState({
      isLoading: false,
      hasError: true,
      itemCount: 0,
      hasCurrentEligibility: false,
    }),
    "error",
  );
  assert.equal(
    getTaskRecoveryListViewState({
      isLoading: false,
      hasError: false,
      itemCount: 0,
      hasCurrentEligibility: true,
    }),
    "empty",
  );
  assert.equal(
    getTaskRecoveryListViewState({
      isLoading: false,
      hasError: true,
      itemCount: 1,
      hasCurrentEligibility: false,
    }),
    "error",
    "stale entries are hidden when a refresh fails",
  );
});

test("after suspension, stale recovery rows and actions stay hidden until DB rechecks them", () => {
  const staleDeadline = {
    can_restore: true,
    expires_at: "2026-11-01T00:00:00.000Z",
    eligibility_checked_at: "2026-10-31T23:59:00.000Z",
  };
  assert.equal(
    getTaskRecoveryListViewState({
      isLoading: true,
      hasError: false,
      itemCount: 1,
      hasCurrentEligibility: false,
    }),
    "loading",
  );
  assert.equal(
    getTaskRecoveryListViewState({
      isLoading: false,
      hasError: true,
      itemCount: 1,
      hasCurrentEligibility: false,
    }),
    "error",
  );
  assert.equal(
    isTaskRecoveryRestorableAtMonotonicTime(
      staleDeadline,
      1_000,
      70_000,
      false,
    ),
    false,
    "a throttled timer cannot keep a stale restore action available after resume",
  );
  assert.equal(
    getTaskRecoveryListViewState({
      isLoading: false,
      hasError: false,
      itemCount: 1,
      hasCurrentEligibility: true,
    }),
    "ready",
  );
  assert.equal(
    isTaskRecoveryRestorableAtMonotonicTime(
      { ...staleDeadline, can_restore: false },
      70_000,
      70_000,
      true,
    ),
    false,
    "after resume, the fresh database result remains authoritative",
  );
});

test("recovery errors stay generic except for the current board access result", () => {
  assert.equal(
    taskRecoveryLoadErrorMessage("access_denied"),
    "Ya no tienes permiso para ver la recuperación de este tablero.",
  );
  assert.equal(
    taskRecoveryLoadErrorMessage("uncertain"),
    "No se pudo cargar la recuperación. Actualiza la lista para volver a intentarlo.",
  );
  assert.equal(
    taskRecoveryRestoreErrorMessage("uncertain"),
    "No se pudo confirmar si la tarea se recuperó. Actualiza el tablero y la lista antes de volver a intentarlo.",
  );
  assert.equal(
    taskRecoveryRestoreErrorMessage("expired"),
    "El plazo de recuperación venció. Esta tarea ya no se puede recuperar.",
  );
  assert.equal(
    taskRecoveryRestoreErrorMessage("unavailable"),
    "No se pudo recuperar la tarea. Actualiza la lista y revisa el destino.",
  );
});

test("a current access denial clears previously loaded task content", () => {
  assert.equal(shouldClearTaskRecoveryItems("access_denied"), true);
  assert.equal(shouldClearTaskRecoveryItems("uncertain"), false);
});

test("a current original column enables restore without choosing a destination", () => {
  assert.deepEqual(
    getTaskRecoveryRestoreAction(
      { can_restore: true, original_column_id: "column-origin" },
      ["column-origin", "column-destination"],
      null,
    ),
    {
      canRestore: true,
      destinationColumnId: "column-origin",
      needsDestination: false,
      reason: null,
    },
  );
});

test("a removed parent column requires an explicit current destination", () => {
  assert.deepEqual(
    getTaskRecoveryRestoreAction(
      { can_restore: true, original_column_id: "removed-column" },
      ["column-current"],
      null,
    ),
    {
      canRestore: false,
      destinationColumnId: null,
      needsDestination: true,
      reason: "needs_destination",
    },
  );
  assert.deepEqual(
    getTaskRecoveryRestoreAction(
      { can_restore: true, original_column_id: "removed-column" },
      ["column-current"],
      "column-current",
    ),
    {
      canRestore: true,
      destinationColumnId: "column-current",
      needsDestination: false,
      reason: null,
    },
  );
});

test("expired items and destinations from another board cannot restore", () => {
  assert.deepEqual(
    getTaskRecoveryRestoreAction(
      { can_restore: false, original_column_id: "column-origin" },
      ["column-origin"],
      null,
    ),
    {
      canRestore: false,
      destinationColumnId: null,
      needsDestination: false,
      reason: "expired",
    },
  );
  assert.equal(
    getTaskRecoveryRestoreAction(
      { can_restore: true, original_column_id: "removed-column" },
      ["column-current"],
      "foreign-column",
    ).canRestore,
    false,
  );
});

test("recovery deadlines are formatted in the board IANA zone with offset", () => {
  const timestamp = "2026-11-01T00:00:00.000Z";
  const buenosAires = formatTaskRecoveryTimestamp(
    timestamp,
    "America/Argentina/Buenos_Aires",
  );
  const madrid = formatTaskRecoveryTimestamp(timestamp, "Europe/Madrid");
  assert.match(buenosAires, /31\/10\/2026, 21:00:00 GMT-3/);
  assert.match(madrid, /01\/11\/2026, 01:00:00 GMT\+1/);
});

test("user requested deletion has a clear Spanish cause label", () => {
  assert.equal(
    taskRecoveryCauseLabel("user_requested"),
    "Eliminada manualmente",
  );
});
