import assert from "node:assert/strict";
import { test } from "node:test";
import { isTaskEditReadAccessDeniedCode } from "../../src/lib/task-edit-read.ts";

test("only the authorization SQLSTATE retires the task-edit session", () => {
  assert.equal(isTaskEditReadAccessDeniedCode("42501"), true);
  assert.equal(isTaskEditReadAccessDeniedCode("23514"), false);
  assert.equal(isTaskEditReadAccessDeniedCode("08006"), false);
  assert.equal(isTaskEditReadAccessDeniedCode(undefined), false);
});
