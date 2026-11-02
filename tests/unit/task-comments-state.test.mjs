import assert from "node:assert/strict";
import { test } from "node:test";
import { parseTaskCommentPage } from "../../src/lib/db/task-comments.ts";
import {
  getOrCreateTaskCommentCreateCommand,
  getTaskCommentThreadViewState,
  mergeTaskComments,
  shouldRetainTaskCommentCommand,
  TaskCommentCreateOperationStore,
  taskCommentAccessEffect,
  taskCommentCreateFollowUp,
  taskCommentTextSegments,
} from "../../src/lib/task-comments-state.ts";

const comment = (id, createdAt, content = id) => ({
  id,
  author_id: "author-1",
  author_name: "Ana",
  created_at: createdAt,
  edited_at: null,
  version: 1,
  deleted: false,
  content,
  mentions: [],
});

test("comment pages merge chronologically with stable id ties and no duplicate rows", () => {
  const firstPage = [
    comment("comment-b", "2026-11-01T12:00:00.000Z"),
    comment("comment-a", "2026-11-01T12:00:00.000Z"),
  ];
  const olderPage = [
    comment("comment-c", "2026-10-31T12:00:00.000Z"),
    comment("comment-a", "2026-11-01T12:00:00.000Z", "duplicado de página"),
  ];

  assert.deepEqual(
    mergeTaskComments(firstPage, olderPage).map(({ id }) => id),
    ["comment-c", "comment-a", "comment-b"],
  );
  assert.equal(mergeTaskComments(firstPage, olderPage)[1].content, "comment-a");
});

test("unavailable comment pages never retain or expose private rows", () => {
  const parsed = parseTaskCommentPage({
    status: "unavailable",
    comments: [
      comment("private-comment", "2026-11-01T12:00:00.000Z", "secreto"),
    ],
  });

  assert.deepEqual(parsed, { status: "unavailable" });
  assert.equal(
    getTaskCommentThreadViewState({
      isLoading: false,
      error: null,
      pageStatus: parsed.status,
      commentCount: 0,
    }),
    "access-lost",
  );
});

test("a narrow forbidden action preserves private conversation and draft state", () => {
  assert.deepEqual(taskCommentAccessEffect("forbidden"), {
    accessLost: false,
    preserveDraft: true,
  });
  assert.deepEqual(taskCommentAccessEffect("unavailable"), {
    accessLost: true,
    preserveDraft: false,
  });
});

test("thread view maps initial loading, recoverable error, empty, and ready separately", () => {
  const view = (input) => getTaskCommentThreadViewState(input);
  assert.equal(
    view({ isLoading: true, error: null, pageStatus: null, commentCount: 0 }),
    "loading",
  );
  assert.equal(
    view({
      isLoading: false,
      error: "fallo",
      pageStatus: null,
      commentCount: 0,
    }),
    "error",
  );
  assert.equal(
    view({
      isLoading: false,
      error: null,
      pageStatus: "available",
      commentCount: 0,
    }),
    "empty",
  );
  assert.equal(
    view({
      isLoading: false,
      error: null,
      pageStatus: "available",
      commentCount: 2,
    }),
    "ready",
  );
  assert.equal(
    view({
      isLoading: false,
      error: "older page failed",
      pageStatus: "available",
      commentCount: 2,
    }),
    "ready",
  );
  assert.equal(
    view({
      isLoading: true,
      error: null,
      pageStatus: "unavailable",
      commentCount: 2,
    }),
    "access-lost",
  );
});

test("composer outcomes distinguish confirmed, uncertain and expired results", () => {
  assert.deepEqual(taskCommentCreateFollowUp("confirmed"), {
    clearDraft: true,
    clearPendingCommand: true,
    clearThread: false,
    refreshThread: true,
    requiresReview: false,
  });
  assert.deepEqual(taskCommentCreateFollowUp("uncertain"), {
    clearDraft: false,
    clearPendingCommand: false,
    clearThread: false,
    refreshThread: false,
    requiresReview: false,
  });
  assert.deepEqual(taskCommentCreateFollowUp("expired_unknown"), {
    clearDraft: false,
    clearPendingCommand: false,
    clearThread: false,
    refreshThread: true,
    requiresReview: true,
  });
  assert.deepEqual(taskCommentCreateFollowUp("unavailable"), {
    clearDraft: true,
    clearPendingCommand: true,
    clearThread: true,
    refreshThread: false,
    requiresReview: false,
  });
});

test("uncertain comment retry keeps the exact in-memory operation and payload", () => {
  const pendingCommands = new TaskCommentCreateOperationStore(
    "actor-1",
    "board-1",
  );
  const first = getOrCreateTaskCommentCreateCommand(
    pendingCommands.get("task-1"),
    "task-1",
    "Texto que pudo haberse guardado",
    [{ user_id: "member-1", start_char: 0, length_chars: 6 }],
    "operation-1",
  );
  pendingCommands.set(first);
  pendingCommands.markCreateExpiredUnknown("task-1");
  assert.equal(pendingCommands.isCreateExpiredUnknown("task-1"), true);
  assert.equal(
    new TaskCommentCreateOperationStore(
      "actor-2",
      "board-1",
    ).isCreateExpiredUnknown("task-1"),
    false,
  );

  const retry = getOrCreateTaskCommentCreateCommand(
    pendingCommands.get("task-1"),
    "task-1",
    "otro texto",
    [],
    "operation-2",
  );
  assert.deepEqual(retry, first);
  assert.equal(
    new TaskCommentCreateOperationStore("actor-2", "board-1").get("task-1"),
    null,
  );

  pendingCommands.clear("task-1");
  assert.equal(pendingCommands.get("task-1"), null);
  assert.equal(pendingCommands.isCreateExpiredUnknown("task-1"), false);
});

test("expired receipts retain the same operation until reconciliation", () => {
  assert.equal(shouldRetainTaskCommentCommand("expired_unknown"), true);
  assert.equal(shouldRetainTaskCommentCommand("confirmed"), false);
  assert.equal(shouldRetainTaskCommentCommand("conflict"), false);
  assert.equal(shouldRetainTaskCommentCommand("unavailable"), false);
});

test("edit, delete, and restore keep their original commands in the session store", () => {
  const operations = new TaskCommentCreateOperationStore("actor-1", "board-1");
  const edit = {
    task_id: "task-1",
    comment_id: "comment-1",
    operation_id: "edit-operation",
    expected_version: 2,
    content: "Texto editado",
    mentions: [{ user_id: "member-1", start_char: 0, length_chars: 6 }],
  };
  const deletion = {
    action: "delete",
    task_id: "task-1",
    comment_id: "comment-1",
    operation_id: "delete-operation",
  };
  const restoration = {
    action: "restore",
    task_id: "task-1",
    comment_id: "comment-1",
    operation_id: "restore-operation",
  };

  operations.setEdit(edit);
  operations.setAction(deletion);
  operations.setAction(restoration);
  operations.markEditExpiredUnknown("task-1", "comment-1");
  operations.markActionExpiredUnknown("delete", "task-1", "comment-1");
  operations.markActionExpiredUnknown("restore", "task-1", "comment-1");
  assert.deepEqual(operations.getEdit("task-1", "comment-1"), edit);
  assert.deepEqual(
    operations.getAction("delete", "task-1", "comment-1"),
    deletion,
  );
  assert.deepEqual(
    operations.getAction("restore", "task-1", "comment-1"),
    restoration,
  );
  assert.equal(operations.isEditExpiredUnknown("task-1", "comment-1"), true);
  assert.equal(
    operations.isActionExpiredUnknown("delete", "task-1", "comment-1"),
    true,
  );
  assert.equal(
    operations.isActionExpiredUnknown("restore", "task-1", "comment-1"),
    true,
  );
  operations.clearEdit("task-1", "comment-1");
  operations.clearAction("delete", "task-1", "comment-1");
  operations.clearAction("restore", "task-1", "comment-1");
  assert.equal(operations.isEditExpiredUnknown("task-1", "comment-1"), false);
  assert.equal(
    operations.isActionExpiredUnknown("delete", "task-1", "comment-1"),
    false,
  );
  assert.equal(
    operations.isActionExpiredUnknown("restore", "task-1", "comment-1"),
    false,
  );
});

test("comment rendering keeps content literal and unlinked mentions unlinked", () => {
  const content = "<b>https://example.invalid</b> @Ana @Beto";
  const segments = taskCommentTextSegments({
    content,
    mentions: [
      {
        start_char: 31,
        length_chars: 4,
        text: "@Ana",
        user_id: "member-1",
      },
      {
        start_char: 36,
        length_chars: 5,
        text: "@Beto",
      },
    ],
  });
  assert.deepEqual(segments, [
    { text: "<b>https://example.invalid</b> ", isCurrentMember: false },
    { text: "@Ana", isCurrentMember: true },
    { text: " ", isCurrentMember: false },
    { text: "@Beto", isCurrentMember: false },
  ]);
});
