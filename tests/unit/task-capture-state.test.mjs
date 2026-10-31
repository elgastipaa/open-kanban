import assert from "node:assert/strict";
import { test } from "node:test";
import {
  taskCaptureErrorReasonFromCode,
  taskCaptureFailureTransition,
} from "../../src/lib/task-capture-state.ts";

test("an access denial is distinct from recoverable database outcomes", () => {
  assert.equal(taskCaptureErrorReasonFromCode("42501"), "access_denied");
  assert.equal(taskCaptureErrorReasonFromCode("55000"), null);
});

test("a denied capture removes the pending title and composer immediately", () => {
  assert.deepEqual(
    taskCaptureFailureTransition("Borrador confidencial", "access_denied"),
    {
      title: "",
      errorReason: "access_denied",
      removeComposer: true,
    },
  );
});

test("a recoverable unavailable capture keeps its draft for reconciliation", () => {
  assert.deepEqual(
    taskCaptureFailureTransition("Borrador recuperable", "unavailable"),
    {
      title: "Borrador recuperable",
      errorReason: "unavailable",
      removeComposer: false,
    },
  );
});
