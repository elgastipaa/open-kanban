import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  TaskComment,
  TaskCommentCreateCommand,
  TaskCommentCreateResult,
  TaskCommentCursor,
  TaskCommentEditCommand,
  TaskCommentMention,
  TaskCommentMutationResult,
  TaskCommentPage,
} from "../types";

export type TaskCommentErrorReason =
  | "forbidden"
  | "conflict"
  | "expired_unknown"
  | "rejected"
  | "uncertain";

export class TaskCommentError extends Error {
  readonly reason: TaskCommentErrorReason;

  constructor(reason: TaskCommentErrorReason) {
    super("No se pudo confirmar el cambio de conversación.");
    this.name = "TaskCommentError";
    this.reason = reason;
  }
}

export interface TaskCommentPageRequest {
  limit: number;
  cursor: TaskCommentCursor | null;
  anchorCommentId: string | null;
}

const defaultPageRequest: TaskCommentPageRequest = {
  limit: 30,
  cursor: null,
  anchorCommentId: null,
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && Number.isFinite(Date.parse(value));
}

function parseCursor(value: unknown): TaskCommentCursor | null {
  if (!isRecord(value) || !isTimestamp(value.created_at)) return null;
  if (typeof value.id !== "string" || value.id.length === 0) return null;
  return { created_at: value.created_at, id: value.id };
}

function parseMention(value: unknown): TaskCommentMention | null {
  if (
    !isRecord(value) ||
    !Number.isSafeInteger(value.start_char) ||
    Number(value.start_char) < 0 ||
    !Number.isSafeInteger(value.length_chars) ||
    Number(value.length_chars) < 1 ||
    typeof value.text !== "string" ||
    (value.user_id !== undefined && typeof value.user_id !== "string")
  ) {
    return null;
  }
  return {
    start_char: Number(value.start_char),
    length_chars: Number(value.length_chars),
    text: value.text,
    ...(typeof value.user_id === "string" ? { user_id: value.user_id } : {}),
  };
}

function parseComment(value: unknown): TaskComment | null {
  if (
    !isRecord(value) ||
    typeof value.id !== "string" ||
    typeof value.author_id !== "string" ||
    typeof value.author_name !== "string" ||
    !isTimestamp(value.created_at) ||
    typeof value.deleted !== "boolean"
  ) {
    return null;
  }
  const editedAt = value.edited_at ?? null;
  if (editedAt !== null && !isTimestamp(editedAt)) return null;
  const version = value.version ?? null;
  if (
    version !== null &&
    (!Number.isSafeInteger(version) || Number(version) < 1)
  ) {
    return null;
  }

  if (value.deleted) {
    if (
      (value.can_restore !== undefined &&
        typeof value.can_restore !== "boolean") ||
      (value.expires_at !== undefined && !isTimestamp(value.expires_at))
    ) {
      return null;
    }
    return {
      id: value.id,
      author_id: value.author_id,
      author_name: value.author_name,
      created_at: value.created_at,
      edited_at: typeof editedAt === "string" ? editedAt : null,
      version: null,
      deleted: true,
      content: null,
      ...(typeof value.can_restore === "boolean"
        ? { can_restore: value.can_restore }
        : {}),
      ...(isTimestamp(value.expires_at)
        ? { expires_at: value.expires_at }
        : {}),
      mentions: [],
    };
  }
  if (typeof value.content !== "string" || !Array.isArray(value.mentions)) {
    return null;
  }
  const mentions = value.mentions.map(parseMention);
  if (mentions.some((mention) => mention === null)) return null;
  return {
    id: value.id,
    author_id: value.author_id,
    author_name: value.author_name,
    created_at: value.created_at,
    edited_at: typeof editedAt === "string" ? editedAt : null,
    version: typeof version === "number" ? version : null,
    deleted: false,
    content: value.content,
    mentions: mentions as TaskCommentMention[],
  };
}

export function parseTaskCommentPage(value: unknown): TaskCommentPage | null {
  if (!isRecord(value)) return null;
  if (value.status === "unavailable") return { status: "unavailable" };
  if (
    value.status !== "available" ||
    !Array.isArray(value.comments) ||
    typeof value.has_more !== "boolean"
  ) {
    return null;
  }
  const comments = value.comments.map(parseComment);
  if (comments.some((comment) => comment === null)) return null;
  const cursor =
    value.next_cursor === null ? null : parseCursor(value.next_cursor);
  if (value.has_more !== (cursor !== null)) return null;
  const anchorId = value.anchor_id;
  const anchorIndex = value.anchor_index;
  if (anchorId !== undefined || anchorIndex !== undefined) {
    if (
      typeof anchorId !== "string" ||
      !Number.isSafeInteger(anchorIndex) ||
      Number(anchorIndex) < 0 ||
      Number(anchorIndex) >= comments.length ||
      comments[Number(anchorIndex)]?.id !== anchorId
    ) {
      return null;
    }
    return {
      status: "available",
      comments: comments as TaskComment[],
      has_more: value.has_more,
      next_cursor: cursor,
      anchor_id: anchorId,
      anchor_index: Number(anchorIndex),
    };
  }
  return {
    status: "available",
    comments: comments as TaskComment[],
    has_more: value.has_more,
    next_cursor: cursor,
  };
}

function commentErrorForCode(code: string | undefined): TaskCommentError {
  if (code === "42501") return new TaskCommentError("forbidden");
  if (code === "22023" || code === "22P02") {
    return new TaskCommentError("rejected");
  }
  if (code === "23514") return new TaskCommentError("conflict");
  return new TaskCommentError("uncertain");
}

function isMentionInput(value: unknown): boolean {
  return (
    typeof value === "object" &&
    value !== null &&
    "user_id" in value &&
    typeof value.user_id === "string" &&
    value.user_id.length > 0 &&
    "start_char" in value &&
    Number.isSafeInteger(value.start_char) &&
    Number(value.start_char) >= 0 &&
    "length_chars" in value &&
    Number.isSafeInteger(value.length_chars) &&
    Number(value.length_chars) > 0
  );
}

function parseMutationResult(
  value: unknown,
  operationId: string,
): TaskCommentMutationResult {
  if (
    typeof value !== "object" ||
    value === null ||
    !("status" in value) ||
    typeof value.status !== "string"
  ) {
    throw new TaskCommentError("uncertain");
  }
  const status = value.status;
  const allowed: readonly TaskCommentMutationResult["status"][] = [
    "confirmed",
    "conflict",
    "unavailable",
    "forbidden",
    "expired",
    "expired_unknown",
  ];
  if (
    typeof status !== "string" ||
    !allowed.includes(status as TaskCommentMutationResult["status"])
  ) {
    throw new TaskCommentError("uncertain");
  }
  const resultStatus = status as TaskCommentMutationResult["status"];
  if (
    "operation_id" in value &&
    typeof value.operation_id === "string" &&
    value.operation_id !== operationId
  ) {
    throw new TaskCommentError("conflict");
  }

  if (resultStatus === "confirmed") {
    if (!("comment_id" in value) || typeof value.comment_id !== "string") {
      throw new TaskCommentError("uncertain");
    }
    const result: TaskCommentMutationResult = {
      status: resultStatus,
      operation_id: operationId,
      comment_id: value.comment_id,
    };
    if (
      "version" in value &&
      typeof value.version === "number" &&
      Number.isSafeInteger(value.version) &&
      value.version > 0
    ) {
      result.version = value.version;
    }
    if (
      "deletion_cause" in value &&
      (value.deletion_cause === "author" ||
        value.deletion_cause === "moderation")
    ) {
      result.deletion_cause = value.deletion_cause;
    }
    if ("deleted_at" in value && typeof value.deleted_at === "string") {
      result.deleted_at = value.deleted_at;
    }
    return result;
  }

  return {
    status: resultStatus,
    operation_id: operationId,
    ...("comment_id" in value && typeof value.comment_id === "string"
      ? { comment_id: value.comment_id }
      : {}),
    ...("version" in value && typeof value.version === "number"
      ? { version: value.version }
      : {}),
  };
}

async function callCommentMutation(
  supabase: SupabaseClient,
  rpcName: string,
  args: Record<string, unknown>,
  operationId: string,
): Promise<TaskCommentMutationResult> {
  let response: Awaited<ReturnType<SupabaseClient["rpc"]>>;
  try {
    response = await supabase.rpc(rpcName, args);
  } catch {
    throw new TaskCommentError("uncertain");
  }
  if (response.error) throw commentErrorForCode(response.error.code);
  return parseMutationResult(response.data, operationId);
}

export async function listTaskComments(
  supabase: SupabaseClient,
  slug: string,
  taskId: string,
  request: Partial<TaskCommentPageRequest> = {},
): Promise<TaskCommentPage> {
  const pageRequest = { ...defaultPageRequest, ...request };
  if (
    !slug ||
    !taskId ||
    !Number.isSafeInteger(pageRequest.limit) ||
    pageRequest.limit < 1 ||
    pageRequest.limit > 100 ||
    (pageRequest.anchorCommentId !== null && pageRequest.cursor !== null)
  ) {
    throw new TaskCommentError("rejected");
  }

  let response: Awaited<ReturnType<SupabaseClient["rpc"]>>;
  try {
    response = await supabase.rpc("get_task_comments_p", {
      p_slug: slug,
      p_task_id: taskId,
      p_limit: pageRequest.limit,
      p_before_created_at: pageRequest.cursor?.created_at ?? null,
      p_before_id: pageRequest.cursor?.id ?? null,
      p_anchor_comment_id: pageRequest.anchorCommentId,
    });
  } catch {
    throw new TaskCommentError("uncertain");
  }
  if (response.error) throw commentErrorForCode(response.error.code);
  const page = parseTaskCommentPage(response.data);
  if (!page) throw new TaskCommentError("uncertain");
  return page;
}

export async function createTaskComment(
  supabase: SupabaseClient,
  slug: string,
  command: TaskCommentCreateCommand,
): Promise<TaskCommentCreateResult> {
  if (
    !slug ||
    !command.task_id ||
    !command.operation_id ||
    !command.content.trim() ||
    !Array.isArray(command.mentions) ||
    !command.mentions.every(isMentionInput)
  ) {
    throw new TaskCommentError("rejected");
  }
  const result = await callCommentMutation(
    supabase,
    "create_task_comment_p",
    {
      p_operation_id: command.operation_id,
      p_slug: slug,
      p_task_id: command.task_id,
      p_content: command.content,
      p_mentions: command.mentions,
    },
    command.operation_id,
  );
  if (result.status === "expired") {
    throw new TaskCommentError("uncertain");
  }
  return result;
}

export async function editTaskComment(
  supabase: SupabaseClient,
  slug: string,
  command: TaskCommentEditCommand,
): Promise<TaskCommentMutationResult> {
  if (
    !slug ||
    !command.comment_id ||
    !command.operation_id ||
    !Number.isSafeInteger(command.expected_version) ||
    command.expected_version < 1 ||
    !command.content.trim() ||
    !Array.isArray(command.mentions) ||
    !command.mentions.every(isMentionInput)
  ) {
    throw new TaskCommentError("rejected");
  }
  return callCommentMutation(
    supabase,
    "edit_task_comment_p",
    {
      p_operation_id: command.operation_id,
      p_slug: slug,
      p_comment_id: command.comment_id,
      p_expected_version: command.expected_version,
      p_content: command.content,
      p_mentions: command.mentions,
    },
    command.operation_id,
  );
}

export function deleteTaskComment(
  supabase: SupabaseClient,
  slug: string,
  operationId: string,
  commentId: string,
): Promise<TaskCommentMutationResult> {
  if (!slug || !operationId || !commentId) {
    throw new TaskCommentError("rejected");
  }
  return callCommentMutation(
    supabase,
    "delete_task_comment_p",
    {
      p_operation_id: operationId,
      p_slug: slug,
      p_comment_id: commentId,
    },
    operationId,
  );
}

export function restoreTaskComment(
  supabase: SupabaseClient,
  slug: string,
  operationId: string,
  commentId: string,
): Promise<TaskCommentMutationResult> {
  if (!slug || !operationId || !commentId) {
    throw new TaskCommentError("rejected");
  }
  return callCommentMutation(
    supabase,
    "restore_task_comment_p",
    {
      p_operation_id: operationId,
      p_slug: slug,
      p_comment_id: commentId,
    },
    operationId,
  );
}
