import assert from "node:assert/strict";
import { test } from "node:test";
import {
  createTaskComment,
  deleteTaskComment,
  editTaskComment,
  listTaskComments,
  restoreTaskComment,
  TaskCommentError,
} from "../../src/lib/db/task-comments.ts";

test("thread adapter sends cursor and anchor explicitly and parses its page", async () => {
  const calls = [];
  const supabase = {
    async rpc(name, args) {
      calls.push({ name, args });
      return {
        data: {
          status: "available",
          comments: [
            {
              id: "comment-1",
              author_id: "author-1",
              author_name: "Ana",
              created_at: "2026-11-01T12:00:00.000Z",
              edited_at: null,
              version: 1,
              deleted: false,
              content: "Hola",
              mentions: [],
            },
          ],
          has_more: true,
          next_cursor: {
            created_at: "2026-11-01T12:00:00.000Z",
            id: "comment-1",
          },
          anchor_id: "comment-1",
          anchor_index: 0,
        },
        error: null,
      };
    },
  };

  const page = await listTaskComments(supabase, "board", "task", {
    limit: 1,
    cursor: null,
    anchorCommentId: "comment-1",
  });
  assert.equal(calls[0].name, "get_task_comments_p");
  assert.deepEqual(calls[0].args, {
    p_slug: "board",
    p_task_id: "task",
    p_limit: 1,
    p_before_created_at: null,
    p_before_id: null,
    p_anchor_comment_id: "comment-1",
  });
  assert.equal(page.status, "available");
  assert.equal(page.anchor_id, "comment-1");
  assert.equal(page.comments[0].content, "Hola");
});

test("comment create maps an expired receipt without re-sending a new operation", async () => {
  const calls = [];
  const supabase = {
    async rpc(name, args) {
      calls.push({ name, args });
      return {
        data: { status: "expired_unknown", operation_id: "operation-1" },
        error: null,
      };
    },
  };
  const command = {
    task_id: "task-1",
    operation_id: "operation-1",
    content: "No sé si se guardó",
    mentions: [],
  };

  const result = await createTaskComment(supabase, "board", command);
  assert.equal(result.status, "expired_unknown");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].args.p_operation_id, command.operation_id);
});

test("edit/delete/restore adapters preserve operation IDs on expired receipts", async () => {
  const calls = [];
  const supabase = {
    async rpc(name, args) {
      calls.push({ name, args });
      return {
        data: { status: "expired_unknown", operation_id: args.p_operation_id },
        error: null,
      };
    },
  };
  const edit = await editTaskComment(supabase, "board", {
    task_id: "task-1",
    comment_id: "comment-1",
    operation_id: "edit-operation",
    expected_version: 2,
    content: "Texto editado",
    mentions: [],
  });
  const deletion = await deleteTaskComment(
    supabase,
    "board",
    "delete-operation",
    "comment-1",
  );
  const restoration = await restoreTaskComment(
    supabase,
    "board",
    "restore-operation",
    "comment-1",
  );

  assert.deepEqual(
    [edit, deletion, restoration].map(({ status, operation_id }) => ({
      status,
      operation_id,
    })),
    [
      { status: "expired_unknown", operation_id: "edit-operation" },
      { status: "expired_unknown", operation_id: "delete-operation" },
      { status: "expired_unknown", operation_id: "restore-operation" },
    ],
  );
  assert.deepEqual(
    calls.map(({ name, args }) => [name, args.p_operation_id]),
    [
      ["edit_task_comment_p", "edit-operation"],
      ["delete_task_comment_p", "delete-operation"],
      ["restore_task_comment_p", "restore-operation"],
    ],
  );
});

test("edit/delete/restore map narrow action denials without exposing private details", async () => {
  const calls = [];
  const supabase = {
    async rpc(name, args) {
      calls.push({ name, args });
      return {
        data: {
          status: "forbidden",
          operation_id: args.p_operation_id,
          comment_id: "comment-1",
        },
        error: null,
      };
    },
  };

  const edit = await editTaskComment(supabase, "board", {
    task_id: "task-1",
    comment_id: "comment-1",
    operation_id: "edit-forbidden",
    expected_version: 1,
    content: "Borrador local",
    mentions: [],
  });
  const deletion = await deleteTaskComment(
    supabase,
    "board",
    "delete-forbidden",
    "comment-1",
  );
  const restoration = await restoreTaskComment(
    supabase,
    "board",
    "restore-forbidden",
    "comment-1",
  );

  assert.deepEqual(
    [edit, deletion, restoration].map(({ status, operation_id }) => ({
      status,
      operation_id,
    })),
    [
      { status: "forbidden", operation_id: "edit-forbidden" },
      { status: "forbidden", operation_id: "delete-forbidden" },
      { status: "forbidden", operation_id: "restore-forbidden" },
    ],
  );
  assert.equal(calls.length, 3);
});

test("restore adapter preserves an explicit deadline expiry result", async () => {
  const supabase = {
    async rpc(_name, args) {
      return {
        data: { status: "expired", operation_id: args.p_operation_id },
        error: null,
      };
    },
  };
  const result = await restoreTaskComment(
    supabase,
    "board",
    "restore-operation",
    "comment-1",
  );
  assert.deepEqual(result, {
    status: "expired",
    operation_id: "restore-operation",
  });
});

test("comment RPC errors expose only typed denial/rejection reasons", async () => {
  for (const [code, reason] of [
    ["42501", "forbidden"],
    ["22023", "rejected"],
    ["23514", "conflict"],
  ]) {
    const supabase = {
      async rpc() {
        return {
          data: null,
          error: { code, message: "private database detail" },
        };
      },
    };
    await assert.rejects(
      createTaskComment(supabase, "board", {
        task_id: "task-1",
        operation_id: `operation-${code}`,
        content: "Comentario válido",
        mentions: [],
      }),
      (error) =>
        error instanceof TaskCommentError &&
        error.reason === reason &&
        !error.message.includes("private database detail"),
    );
  }
});
