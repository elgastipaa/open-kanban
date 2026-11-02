import type {
  TaskComment,
  TaskCommentActionCommand,
  TaskCommentCreateCommand,
  TaskCommentEditCommand,
  TaskCommentMentionInput,
  TaskCommentMutationResult,
  TaskCommentPage,
} from "./types";

type TaskCommentCreateStatus =
  | "confirmed"
  | "conflict"
  | "unavailable"
  | "forbidden"
  | "expired_unknown"
  | "uncertain"
  | "retryable"
  | "rejected";

export type TaskCommentThreadViewState =
  | "loading"
  | "error"
  | "access-lost"
  | "empty"
  | "ready";

export function taskCommentAccessEffect(outcome: string) {
  return {
    accessLost: outcome === "unavailable" || outcome === "access_lost",
    preserveDraft: outcome === "forbidden",
  } as const;
}

export function shouldRetainTaskCommentCommand(
  status: TaskCommentMutationResult["status"],
): boolean {
  return status === "expired_unknown";
}

export function getTaskCommentThreadViewState(input: {
  isLoading: boolean;
  error: string | null;
  pageStatus: TaskCommentPage["status"] | null;
  commentCount: number;
}): TaskCommentThreadViewState {
  if (input.pageStatus === "unavailable") return "access-lost";
  if (input.isLoading && input.commentCount === 0) return "loading";
  if (input.error && input.commentCount === 0) return "error";
  if (input.commentCount === 0) return "empty";
  return "ready";
}

function compareComments(left: TaskComment, right: TaskComment): number {
  const timeDifference =
    Date.parse(left.created_at) - Date.parse(right.created_at);
  if (timeDifference !== 0) return timeDifference;
  if (left.id < right.id) return -1;
  if (left.id > right.id) return 1;
  return 0;
}

function preferComment(
  existing: TaskComment,
  incoming: TaskComment,
): TaskComment {
  if (existing.deleted !== incoming.deleted) return incoming;
  if (
    existing.version !== null &&
    incoming.version !== null &&
    incoming.version > existing.version
  ) {
    return incoming;
  }
  return existing;
}

/** Merge independently loaded pages without moving or duplicating existing rows. */
export function mergeTaskComments(
  existing: readonly TaskComment[],
  incoming: readonly TaskComment[],
): TaskComment[] {
  const byId = new Map(existing.map((comment) => [comment.id, comment]));
  for (const comment of incoming) {
    const current = byId.get(comment.id);
    byId.set(comment.id, current ? preferComment(current, comment) : comment);
  }
  return [...byId.values()].sort(compareComments);
}

export interface TaskCommentTextSegment {
  text: string;
  isCurrentMember: boolean;
}

/** Split safe literal text from mention tokens; no segment is a link or HTML. */
export function taskCommentTextSegments(
  comment: Pick<TaskComment, "content" | "mentions">,
): TaskCommentTextSegment[] {
  const text = comment.content ?? "";
  const characters = Array.from(text);
  const mentions = comment.mentions
    .filter((mention) => {
      if (
        !Number.isSafeInteger(mention.start_char) ||
        mention.start_char < 0 ||
        !Number.isSafeInteger(mention.length_chars) ||
        mention.length_chars < 1 ||
        mention.start_char + mention.length_chars > characters.length
      ) {
        return false;
      }
      return (
        characters
          .slice(mention.start_char, mention.start_char + mention.length_chars)
          .join("") === mention.text
      );
    })
    .sort((left, right) => left.start_char - right.start_char);
  const segments: TaskCommentTextSegment[] = [];
  let cursor = 0;
  for (const mention of mentions) {
    if (mention.start_char < cursor) continue;
    if (mention.start_char > cursor) {
      segments.push({
        text: characters.slice(cursor, mention.start_char).join(""),
        isCurrentMember: false,
      });
    }
    segments.push({
      text: mention.text,
      isCurrentMember: Boolean(mention.user_id),
    });
    cursor = mention.start_char + mention.length_chars;
  }
  if (cursor < characters.length || segments.length === 0) {
    segments.push({
      text: characters.slice(cursor).join(""),
      isCurrentMember: false,
    });
  }
  return segments;
}

export function taskCommentCreateFollowUp(status: TaskCommentCreateStatus) {
  switch (status) {
    case "confirmed":
      return {
        clearDraft: true,
        clearPendingCommand: true,
        clearThread: false,
        refreshThread: true,
        requiresReview: false,
      } as const;
    case "unavailable":
      return {
        clearDraft: true,
        clearPendingCommand: true,
        clearThread: true,
        refreshThread: false,
        requiresReview: false,
      } as const;
    case "expired_unknown":
      return {
        clearDraft: false,
        clearPendingCommand: false,
        clearThread: false,
        refreshThread: true,
        requiresReview: true,
      } as const;
    case "conflict":
      return {
        clearDraft: false,
        clearPendingCommand: true,
        clearThread: false,
        refreshThread: true,
        requiresReview: true,
      } as const;
    case "uncertain":
    case "retryable":
      return {
        clearDraft: false,
        clearPendingCommand: false,
        clearThread: false,
        refreshThread: false,
        requiresReview: false,
      } as const;
    case "rejected":
      return {
        clearDraft: false,
        clearPendingCommand: true,
        clearThread: false,
        refreshThread: false,
        requiresReview: false,
      } as const;
    case "forbidden":
      return {
        clearDraft: false,
        clearPendingCommand: true,
        clearThread: false,
        refreshThread: false,
        requiresReview: false,
      } as const;
  }
}

/** Pending comment payloads stay in this in-memory store for one board session. */
export class TaskCommentCreateOperationStore {
  private readonly commands = new Map<string, TaskCommentCreateCommand>();
  private readonly expiredCreates = new Set<string>();
  private readonly edits = new Map<string, TaskCommentEditCommand>();
  private readonly expiredEdits = new Set<string>();
  private readonly actions = new Map<string, TaskCommentActionCommand>();
  private readonly expiredActions = new Set<string>();
  private readonly actorId: string;
  private readonly boardSlug: string;

  constructor(actorId: string, boardSlug: string) {
    this.actorId = actorId;
    this.boardSlug = boardSlug;
  }

  private key(taskId: string): string {
    return `${this.actorId}:${this.boardSlug}:${taskId}`;
  }

  private editKey(taskId: string, commentId: string): string {
    return `${this.key(taskId)}:edit:${commentId}`;
  }

  private actionKey(
    action: TaskCommentActionCommand["action"],
    taskId: string,
    commentId: string,
  ): string {
    return `${this.key(taskId)}:${action}:${commentId}`;
  }

  get(taskId: string): TaskCommentCreateCommand | null {
    return this.commands.get(this.key(taskId)) ?? null;
  }

  set(command: TaskCommentCreateCommand): void {
    this.commands.set(this.key(command.task_id), command);
  }

  clearCreate(taskId: string): void {
    this.commands.delete(this.key(taskId));
    this.expiredCreates.delete(this.key(taskId));
  }

  markCreateExpiredUnknown(taskId: string): void {
    this.expiredCreates.add(this.key(taskId));
  }

  isCreateExpiredUnknown(taskId: string): boolean {
    return this.expiredCreates.has(this.key(taskId));
  }

  clear(taskId: string): void {
    this.clearCreate(taskId);
    const prefix = `${this.key(taskId)}:`;
    for (const key of this.edits.keys()) {
      if (key.startsWith(prefix)) this.edits.delete(key);
    }
    for (const key of this.expiredEdits) {
      if (key.startsWith(prefix)) this.expiredEdits.delete(key);
    }
    for (const key of this.actions.keys()) {
      if (key.startsWith(prefix)) this.actions.delete(key);
    }
    for (const key of this.expiredActions) {
      if (key.startsWith(prefix)) this.expiredActions.delete(key);
    }
  }

  getEdit(taskId: string, commentId: string): TaskCommentEditCommand | null {
    return this.edits.get(this.editKey(taskId, commentId)) ?? null;
  }

  setEdit(command: TaskCommentEditCommand): void {
    this.edits.set(this.editKey(command.task_id, command.comment_id), command);
  }

  markEditExpiredUnknown(taskId: string, commentId: string): void {
    this.expiredEdits.add(this.editKey(taskId, commentId));
  }

  isEditExpiredUnknown(taskId: string, commentId: string): boolean {
    return this.expiredEdits.has(this.editKey(taskId, commentId));
  }

  clearEdit(taskId: string, commentId: string): void {
    const key = this.editKey(taskId, commentId);
    this.edits.delete(key);
    this.expiredEdits.delete(key);
  }

  getAction(
    action: TaskCommentActionCommand["action"],
    taskId: string,
    commentId: string,
  ): TaskCommentActionCommand | null {
    return this.actions.get(this.actionKey(action, taskId, commentId)) ?? null;
  }

  setAction(command: TaskCommentActionCommand): void {
    this.actions.set(
      this.actionKey(command.action, command.task_id, command.comment_id),
      command,
    );
  }

  markActionExpiredUnknown(
    action: TaskCommentActionCommand["action"],
    taskId: string,
    commentId: string,
  ): void {
    this.expiredActions.add(this.actionKey(action, taskId, commentId));
  }

  isActionExpiredUnknown(
    action: TaskCommentActionCommand["action"],
    taskId: string,
    commentId: string,
  ): boolean {
    return this.expiredActions.has(this.actionKey(action, taskId, commentId));
  }

  clearAction(
    action: TaskCommentActionCommand["action"],
    taskId: string,
    commentId: string,
  ): void {
    const key = this.actionKey(action, taskId, commentId);
    this.actions.delete(key);
    this.expiredActions.delete(key);
  }

  clearAll(): void {
    this.commands.clear();
    this.expiredCreates.clear();
    this.edits.clear();
    this.expiredEdits.clear();
    this.actions.clear();
    this.expiredActions.clear();
  }
}

export function getOrCreateTaskCommentCreateCommand(
  pending: TaskCommentCreateCommand | null,
  taskId: string,
  content: string,
  mentions: readonly TaskCommentMentionInput[],
  operationId: string,
): TaskCommentCreateCommand {
  return (
    pending ?? {
      task_id: taskId,
      operation_id: operationId,
      content,
      mentions: [...mentions],
    }
  );
}
