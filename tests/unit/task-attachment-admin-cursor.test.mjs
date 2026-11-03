import assert from "node:assert/strict";
import { test } from "node:test";
import { readAdminTaskAttachmentCursor } from "../../src/lib/task-attachment-admin-cursor.ts";

const attachmentId = "81000000-0000-4000-8000-000000000001";
const createdAt = "2026-11-02T18:21:57.668278+00:00";

test("allows the first admin page without a cursor", () => {
  assert.deepEqual(readAdminTaskAttachmentCursor(new URLSearchParams()), {
    ok: true,
    cursor: null,
  });
});

test("preserves timestamp precision and parses a complete cursor", () => {
  assert.deepEqual(
    readAdminTaskAttachmentCursor(
      new URLSearchParams({
        cursor_created_at: createdAt,
        cursor_attachment_id: attachmentId,
      }),
    ),
    { ok: true, cursor: { createdAt, attachmentId } },
  );
});

test("rejects a partial, malformed, or unsafe cursor", () => {
  assert.deepEqual(
    readAdminTaskAttachmentCursor(
      new URLSearchParams({ cursor_created_at: createdAt }),
    ),
    { ok: false },
  );
  assert.deepEqual(
    readAdminTaskAttachmentCursor(
      new URLSearchParams({
        cursor_created_at: "not-a-timestamp",
        cursor_attachment_id: attachmentId,
      }),
    ),
    { ok: false },
  );
  assert.deepEqual(
    readAdminTaskAttachmentCursor(
      new URLSearchParams({
        cursor_created_at: createdAt,
        cursor_attachment_id: "../../private-object",
      }),
    ),
    { ok: false },
  );
  assert.deepEqual(
    readAdminTaskAttachmentCursor(
      new URLSearchParams(
        `cursor_created_at=${encodeURIComponent(createdAt)}&cursor_attachment_id=${attachmentId}&cursor_attachment_id=${attachmentId}`,
      ),
    ),
    { ok: false },
  );
});
