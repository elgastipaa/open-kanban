import assert from "node:assert/strict";
import { test } from "node:test";
import { getTaskAssigneeLabel } from "../../src/lib/task-assignee-label.ts";

const currentMemberNames = {
  "member-1": "Lucía García",
  "member-2": "martin@example.test",
};

test("assigned cards show a name from the authorized current board roster", () => {
  assert.equal(
    getTaskAssigneeLabel("member-1", currentMemberNames),
    "Lucía García",
  );
});

test("unassigned cards omit the responsible label", () => {
  assert.equal(getTaskAssigneeLabel(null, currentMemberNames), null);
});

test("assignees absent from the current roster reveal no identifier", () => {
  assert.equal(
    getTaskAssigneeLabel("revoked-or-external-user", currentMemberNames),
    "Responsable no disponible",
  );
});
