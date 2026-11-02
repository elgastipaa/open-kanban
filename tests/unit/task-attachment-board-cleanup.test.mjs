import assert from "node:assert/strict";
import { test } from "node:test";
import {
  parseBoardTaskAttachmentStoragePage,
  parseCompletedTaskAttachmentCleanupPreview,
  readBoardTaskAttachmentCleanupRequest,
  readBoardTaskAttachmentCursor,
} from "../../src/lib/task-attachment-board-cleanup.ts";

const attachmentId = "81000000-0000-4000-8000-000000000001";
const taskId = "82000000-0000-4000-8000-000000000001";
const createdAt = "2026-11-02T18:21:57.668278+00:00";

const page = {
  status: "ok",
  board_usage: {
    active_bytes: 24000,
    recoverable_bytes: 12000,
    reserved_bytes: 0,
    pending_bytes: 0,
    active_count: 1,
    recoverable_count: 1,
  },
  global_capacity: {
    limit_bytes: 200000000,
    used_bytes: 36000,
    warning_threshold_bytes: 160000000,
  },
  items: [
    {
      attachment_id: attachmentId,
      task_id: taskId,
      task_title: "Informe terminado",
      task_completed: true,
      file_name: "informe-final.md",
      size_bytes: 24000,
      state: "active",
      created_at: createdAt,
      deleted_at: null,
      deletion_cause: null,
      expires_at: null,
    },
  ],
  has_more: false,
  next_cursor: null,
};

test("parses the owner file list and keeps only its allowlisted metadata", () => {
  const { status: _status, ...expectedPage } = page;
  assert.deepEqual(parseBoardTaskAttachmentStoragePage(page), expectedPage);
  const parsed = parseBoardTaskAttachmentStoragePage({
    ...page,
    items: [
      { ...page.items[0], object_key: "private/object", sha256: "secret" },
    ],
  });
  assert.ok(parsed);
  assert.equal("object_key" in parsed.items[0], false);
  assert.equal("sha256" in parsed.items[0], false);
});

test("rejects malformed board capacity, task state, or pagination cursors", () => {
  assert.equal(
    parseBoardTaskAttachmentStoragePage({
      ...page,
      global_capacity: { ...page.global_capacity, used_bytes: -1 },
    }),
    null,
  );
  assert.equal(
    parseBoardTaskAttachmentStoragePage({
      ...page,
      items: [{ ...page.items[0], task_completed: "true" }],
    }),
    null,
  );
  assert.deepEqual(readBoardTaskAttachmentCursor(new URLSearchParams()), {
    ok: true,
    cursor: null,
  });
  assert.deepEqual(
    readBoardTaskAttachmentCursor(
      new URLSearchParams({
        cursor_created_at: createdAt,
        cursor_attachment_id: attachmentId,
      }),
    ),
    { ok: true, cursor: { createdAt, attachmentId } },
  );
  assert.deepEqual(
    readBoardTaskAttachmentCursor(
      new URLSearchParams({ cursor_created_at: createdAt }),
    ),
    { ok: false },
  );
});

test("accepts a cleanup preview only when it includes the selected task and file", () => {
  const preview = {
    status: "preview",
    item: {
      attachment_id: attachmentId,
      task_id: taskId,
      task_title: "Informe terminado",
      file_name: "informe-final.md",
      size_bytes: 24000,
      created_at: createdAt,
    },
  };
  assert.deepEqual(parseCompletedTaskAttachmentCleanupPreview(preview), {
    item: preview.item,
  });
  assert.equal(
    parseCompletedTaskAttachmentCleanupPreview({
      ...preview,
      item: { ...preview.item, object_key: "private/object" },
    })?.item.file_name,
    "informe-final.md",
  );
  assert.equal(
    parseCompletedTaskAttachmentCleanupPreview({
      status: "preview",
      item: null,
    }),
    null,
  );
});

test("reads bounded preview and cleanup intents with UUIDs only", async () => {
  const preview = await readBoardTaskAttachmentCleanupRequest(
    new Request("https://openkanban.invalid/cleanup", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "preview", attachment_id: attachmentId }),
    }),
  );
  assert.deepEqual(preview, { action: "preview", attachment_id: attachmentId });

  const cleanup = await readBoardTaskAttachmentCleanupRequest(
    new Request("https://openkanban.invalid/cleanup", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "cleanup",
        attachment_id: attachmentId,
        operation_id: "83000000-0000-4000-8000-000000000001",
      }),
    }),
  );
  assert.deepEqual(cleanup, {
    action: "cleanup",
    attachment_id: attachmentId,
    operation_id: "83000000-0000-4000-8000-000000000001",
  });

  assert.equal(
    await readBoardTaskAttachmentCleanupRequest(
      new Request("https://openkanban.invalid/cleanup", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "cleanup",
          attachment_id: attachmentId,
          operation_id: "invalid",
        }),
      }),
    ),
    null,
  );
  assert.equal(
    await readBoardTaskAttachmentCleanupRequest(
      new Request("https://openkanban.invalid/cleanup", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "preview",
          attachment_id: attachmentId,
          actor_id: "84000000-0000-4000-8000-000000000001",
        }),
      }),
    ),
    null,
  );
  assert.equal(
    await readBoardTaskAttachmentCleanupRequest(
      new Request("https://openkanban.invalid/cleanup", {
        method: "POST",
        body: JSON.stringify({
          action: "preview",
          attachment_id: attachmentId,
        }),
      }),
    ),
    null,
  );
});
