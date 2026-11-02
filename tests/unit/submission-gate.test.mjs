import assert from "node:assert/strict";
import { test } from "node:test";
import { createSubmissionGate } from "../../src/lib/submission-gate.mjs";

test("a gate rejects duplicate work without blocking an independent gate", async () => {
  const firstGate = createSubmissionGate();
  const secondGate = createSubmissionGate();
  let finishFirst;

  const firstSubmission = firstGate(
    () =>
      new Promise((resolve) => {
        finishFirst = resolve;
      }),
  );

  assert.deepEqual(await firstGate(async () => "duplicate"), {
    status: "already_submitting",
  });
  assert.equal(await secondGate(async () => "independent"), "independent");

  finishFirst("first");
  assert.equal(await firstSubmission, "first");
  assert.equal(
    await firstGate(async () => "after completion"),
    "after completion",
  );
});
