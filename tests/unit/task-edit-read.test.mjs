import assert from "node:assert/strict";
import { test } from "node:test";
import {
  classifyBoardSnapshotReadFailure,
  isTaskEditReadAccessDeniedCode,
} from "../../src/lib/task-edit-read.ts";

test("only the authorization SQLSTATE retires the task-edit session", () => {
  assert.equal(isTaskEditReadAccessDeniedCode("42501"), true);
  assert.equal(isTaskEditReadAccessDeniedCode("23514"), false);
  assert.equal(isTaskEditReadAccessDeniedCode("08006"), false);
  assert.equal(isTaskEditReadAccessDeniedCode(undefined), false);
});

test("transport failures remain retryable while explicit PostgREST errors are unavailable", () => {
  assert.equal(
    classifyBoardSnapshotReadFailure({ error: { code: "42501" }, status: 403 }),
    "denied",
  );
  assert.equal(
    classifyBoardSnapshotReadFailure({ error: { code: "" }, status: 0 }),
    "retryable",
  );
  assert.equal(
    classifyBoardSnapshotReadFailure({ error: { code: "08006" }, status: 503 }),
    "unavailable",
  );
});
