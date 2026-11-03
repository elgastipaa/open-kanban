import assert from "node:assert/strict";
import { test } from "node:test";
import { resolveTaskChecklistCompletionReview } from "../../src/lib/task-checklist-completion.ts";
import { getTaskChecklistCompletionReview } from "../../src/lib/task-checklist-state.ts";

const command = {
  id: "task-1",
  operation_id: "operation-1",
  is_completed: true,
  expected_version: 4,
};

test("completion review acceptance reuses the operation and current checklist version", () => {
  const preview = getTaskChecklistCompletionReview({
    status: "confirmation_required",
    operation_id: command.operation_id,
    pending_steps_count: 3,
    checklist_version: 8,
  });
  assert.ok(preview);

  const accepted = resolveTaskChecklistCompletionReview(
    command,
    preview,
    "accept",
  );

  assert.deepEqual(accepted, {
    ...command,
    confirmed_checklist_version: 8,
  });
});

test("a stale checklist review requires a fresh count before acceptance", () => {
  const firstReview = getTaskChecklistCompletionReview({
    status: "confirmation_required",
    operation_id: command.operation_id,
    pending_steps_count: 3,
    checklist_version: 8,
  });
  const refreshedReview = getTaskChecklistCompletionReview({
    status: "conflict",
    operation_id: command.operation_id,
    task: {},
    pending_steps_count: 2,
    checklist_version: 9,
  });
  assert.ok(firstReview);
  assert.ok(refreshedReview);

  const staleAcceptance = resolveTaskChecklistCompletionReview(
    command,
    firstReview,
    "accept",
  );
  const freshAcceptance = resolveTaskChecklistCompletionReview(
    staleAcceptance,
    refreshedReview,
    "accept",
  );

  assert.equal(freshAcceptance?.operation_id, command.operation_id);
  assert.equal(freshAcceptance?.confirmed_checklist_version, 9);
});

test("cancelling a completion review produces no command to send", () => {
  const review = getTaskChecklistCompletionReview({
    status: "confirmation_required",
    operation_id: command.operation_id,
    pending_steps_count: 1,
    checklist_version: 2,
  });
  assert.ok(review);

  assert.equal(
    resolveTaskChecklistCompletionReview(command, review, "cancel"),
    null,
  );
});
