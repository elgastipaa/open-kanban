import assert from "node:assert/strict";
import { test } from "node:test";
import { parseAdminTaskAttachmentCleanupCandidate } from "../../src/lib/task-attachment-admin-candidate.ts";

const candidate = {
  attachment_id: "81000000-0000-4000-8000-000000000001",
  board_reference: "board-reference",
  task_reference: "task-reference",
  owner_reference: "owner-reference",
  size_bytes: 24000,
  created_at: "2026-11-02T18:21:57.668278+00:00",
  state: "active",
  deletion_cause: null,
  task_state: "active",
  expires_at: null,
};

test("accepts only the admin cleanup metadata needed by the panel", () => {
  assert.deepEqual(
    parseAdminTaskAttachmentCleanupCandidate(candidate),
    candidate,
  );
});

test("rejects the uploaded-by identity even when the remaining metadata is valid", () => {
  assert.equal(
    parseAdminTaskAttachmentCleanupCandidate({
      ...candidate,
      uploaded_by_reference: "uploader-reference",
    }),
    null,
  );
  assert.equal(
    parseAdminTaskAttachmentCleanupCandidate({
      ...candidate,
      uploaded_by_reference: null,
    }),
    null,
  );
});
