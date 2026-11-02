const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const TIMESTAMP_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/iu;

export interface BoardTaskAttachmentCleanupItem {
  attachment_id: string;
  task_id: string;
  task_title: string;
  task_completed: boolean;
  file_name: string;
  size_bytes: number;
  state: "active" | "recoverable";
  created_at: string;
  deleted_at: string | null;
  deletion_cause:
    | "author"
    | "moderation"
    | "admin_cleanup"
    | "parent_delete"
    | null;
  expires_at: string | null;
}

export interface BoardTaskAttachmentStoragePage {
  board_usage: {
    active_bytes: number;
    recoverable_bytes: number;
    reserved_bytes: number;
    pending_bytes: number;
    active_count: number;
    recoverable_count: number;
  };
  global_capacity: {
    limit_bytes: number;
    used_bytes: number;
    warning_threshold_bytes: number;
  };
  items: BoardTaskAttachmentCleanupItem[];
  has_more: boolean;
  next_cursor: BoardTaskAttachmentCursor | null;
}

export interface BoardTaskAttachmentCursor {
  createdAt: string;
  attachmentId: string;
}

export interface CompletedTaskAttachmentCleanupPreview {
  attachment_id: string;
  task_id: string;
  task_title: string;
  file_name: string;
  size_bytes: number;
  created_at: string;
}

export type BoardTaskAttachmentCleanupRequest =
  | { action: "preview"; attachment_id: string }
  | { action: "cleanup"; attachment_id: string; operation_id: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSafeCount(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

export async function readBoardTaskAttachmentCleanupRequest(
  request: Request,
): Promise<BoardTaskAttachmentCleanupRequest | null> {
  const contentType = request.headers
    .get("content-type")
    ?.split(";", 1)[0]
    .trim()
    .toLowerCase();
  if (contentType !== "application/json") return null;
  const contentLength = request.headers.get("content-length");
  if (
    contentLength !== null &&
    (!/^\d+$/u.test(contentLength) || Number(contentLength) > 4096)
  ) {
    return null;
  }
  if (!request.body) return null;

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > 4096) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } catch {
    return null;
  } finally {
    reader.releaseLock();
  }

  let payload: unknown;
  try {
    const bytes = new Uint8Array(totalBytes);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    payload = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    );
  } catch {
    return null;
  }

  if (!isRecord(payload) || !isUuid(payload.attachment_id)) return null;
  if (
    payload.action === "preview" &&
    Object.keys(payload).every((key) =>
      ["action", "attachment_id"].includes(key),
    )
  ) {
    return {
      action: "preview",
      attachment_id: payload.attachment_id.toLowerCase(),
    };
  }
  if (
    payload.action === "cleanup" &&
    isUuid(payload.operation_id) &&
    Object.keys(payload).every((key) =>
      ["action", "attachment_id", "operation_id"].includes(key),
    )
  ) {
    return {
      action: "cleanup",
      attachment_id: payload.attachment_id.toLowerCase(),
      operation_id: payload.operation_id.toLowerCase(),
    };
  }
  return null;
}

function isTimestamp(value: unknown): value is string {
  return (
    typeof value === "string" &&
    TIMESTAMP_PATTERN.test(value) &&
    Number.isFinite(Date.parse(value))
  );
}

function isNullableTimestamp(value: unknown): value is string | null {
  return value === null || isTimestamp(value);
}

function parseCleanupItem(
  value: unknown,
): BoardTaskAttachmentCleanupItem | null {
  if (
    !isRecord(value) ||
    !isUuid(value.attachment_id) ||
    !isUuid(value.task_id) ||
    typeof value.task_title !== "string" ||
    typeof value.task_completed !== "boolean" ||
    typeof value.file_name !== "string" ||
    value.file_name.length < 1 ||
    value.file_name.length > 120 ||
    !isSafeCount(value.size_bytes) ||
    (value.state !== "active" && value.state !== "recoverable") ||
    !isTimestamp(value.created_at) ||
    !isNullableTimestamp(value.deleted_at) ||
    (value.deletion_cause !== null &&
      value.deletion_cause !== "author" &&
      value.deletion_cause !== "moderation" &&
      value.deletion_cause !== "admin_cleanup" &&
      value.deletion_cause !== "parent_delete") ||
    !isNullableTimestamp(value.expires_at)
  ) {
    return null;
  }
  return {
    attachment_id: value.attachment_id,
    task_id: value.task_id,
    task_title: value.task_title,
    task_completed: value.task_completed,
    file_name: value.file_name,
    size_bytes: value.size_bytes,
    state: value.state,
    created_at: value.created_at,
    deleted_at: value.deleted_at,
    deletion_cause: value.deletion_cause,
    expires_at: value.expires_at,
  };
}

function parseCursor(value: unknown): BoardTaskAttachmentCursor | null {
  if (
    !isRecord(value) ||
    !isTimestamp(value.created_at) ||
    !isUuid(value.attachment_id)
  ) {
    return null;
  }
  return { createdAt: value.created_at, attachmentId: value.attachment_id };
}

function parseUsage(
  value: unknown,
): BoardTaskAttachmentStoragePage["board_usage"] | null {
  if (
    !isRecord(value) ||
    !isSafeCount(value.active_bytes) ||
    !isSafeCount(value.recoverable_bytes) ||
    !isSafeCount(value.reserved_bytes) ||
    !isSafeCount(value.pending_bytes) ||
    !isSafeCount(value.active_count) ||
    !isSafeCount(value.recoverable_count)
  ) {
    return null;
  }
  return {
    active_bytes: value.active_bytes,
    recoverable_bytes: value.recoverable_bytes,
    reserved_bytes: value.reserved_bytes,
    pending_bytes: value.pending_bytes,
    active_count: value.active_count,
    recoverable_count: value.recoverable_count,
  };
}

function parseCapacity(
  value: unknown,
): BoardTaskAttachmentStoragePage["global_capacity"] | null {
  if (
    !isRecord(value) ||
    value.limit_bytes !== 200000000 ||
    value.warning_threshold_bytes !== 160000000 ||
    !isSafeCount(value.used_bytes)
  ) {
    return null;
  }
  return {
    limit_bytes: value.limit_bytes,
    used_bytes: value.used_bytes,
    warning_threshold_bytes: value.warning_threshold_bytes,
  };
}

export function parseBoardTaskAttachmentStoragePage(
  value: unknown,
): BoardTaskAttachmentStoragePage | null {
  if (
    !isRecord(value) ||
    value.status !== "ok" ||
    !Array.isArray(value.items) ||
    typeof value.has_more !== "boolean"
  ) {
    return null;
  }
  const boardUsage = parseUsage(value.board_usage);
  const globalCapacity = parseCapacity(value.global_capacity);
  const items = value.items.map(parseCleanupItem);
  const nextCursor =
    value.next_cursor === null ? null : parseCursor(value.next_cursor);
  if (
    !boardUsage ||
    !globalCapacity ||
    items.some((item) => item === null) ||
    (value.has_more && !nextCursor) ||
    (!value.has_more && nextCursor)
  ) {
    return null;
  }
  return {
    board_usage: boardUsage,
    global_capacity: globalCapacity,
    items: items as BoardTaskAttachmentCleanupItem[],
    has_more: value.has_more,
    next_cursor: nextCursor,
  };
}

export function parseCompletedTaskAttachmentCleanupPreview(
  value: unknown,
): { item: CompletedTaskAttachmentCleanupPreview } | null {
  if (!isRecord(value) || value.status !== "preview" || !isRecord(value.item)) {
    return null;
  }
  const item = value.item;
  if (
    !isUuid(item.attachment_id) ||
    !isUuid(item.task_id) ||
    typeof item.task_title !== "string" ||
    typeof item.file_name !== "string" ||
    item.file_name.length < 1 ||
    item.file_name.length > 120 ||
    !isSafeCount(item.size_bytes) ||
    !isTimestamp(item.created_at)
  ) {
    return null;
  }
  return {
    item: {
      attachment_id: item.attachment_id,
      task_id: item.task_id,
      task_title: item.task_title,
      file_name: item.file_name,
      size_bytes: item.size_bytes,
      created_at: item.created_at,
    },
  };
}

export function readBoardTaskAttachmentCursor(
  search: URLSearchParams,
): { ok: true; cursor: BoardTaskAttachmentCursor | null } | { ok: false } {
  const createdAtValues = search.getAll("cursor_created_at");
  const attachmentIdValues = search.getAll("cursor_attachment_id");
  if (createdAtValues.length > 1 || attachmentIdValues.length > 1) {
    return { ok: false };
  }
  const createdAt = createdAtValues[0] ?? null;
  const attachmentId = attachmentIdValues[0] ?? null;
  if (createdAt === null && attachmentId === null) {
    return { ok: true, cursor: null };
  }
  if (!isTimestamp(createdAt) || !isUuid(attachmentId)) return { ok: false };
  return { ok: true, cursor: { createdAt, attachmentId } };
}
