export type TaskNotificationReason =
  | "assignment"
  | "comment"
  | "due_date"
  | "mention";

export interface TaskNotificationCursor {
  occurred_at: string;
  id: string;
}

export interface TaskNotificationItem {
  id: string;
  occurred_at: string;
  actor_name: string;
  reason_codes: TaskNotificationReason[];
  task_title: string | null;
  unavailable: boolean;
  read_at: string | null;
}

export type TaskNotificationPage =
  | { status: "unavailable" }
  | {
      status: "available";
      items: TaskNotificationItem[];
      unread_count: number;
      has_more: boolean;
      next_cursor: TaskNotificationCursor | null;
      retention_days: 90;
    };

export type TaskNotificationTarget =
  | { status: "unavailable" }
  | {
      status: "available";
      slug: string;
      task_id: string;
      comment_id: string | null;
    };

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const slugPattern = /^[a-z0-9-]{1,100}$/i;
const reasons = new Set<TaskNotificationReason>([
  "assignment",
  "comment",
  "due_date",
  "mention",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && Number.isFinite(Date.parse(value));
}

function parseCursor(value: unknown): TaskNotificationCursor | null {
  if (
    !isRecord(value) ||
    !isTimestamp(value.occurred_at) ||
    typeof value.id !== "string" ||
    !uuidPattern.test(value.id)
  ) {
    return null;
  }
  return { occurred_at: value.occurred_at, id: value.id };
}

function parseItem(value: unknown): TaskNotificationItem | null {
  if (
    !isRecord(value) ||
    typeof value.id !== "string" ||
    !uuidPattern.test(value.id) ||
    !isTimestamp(value.occurred_at) ||
    typeof value.actor_name !== "string" ||
    value.actor_name.trim() === "" ||
    !Array.isArray(value.reason_codes) ||
    !value.reason_codes.every(
      (reason): reason is TaskNotificationReason =>
        typeof reason === "string" &&
        reasons.has(reason as TaskNotificationReason),
    ) ||
    value.reason_codes.length === 0 ||
    typeof value.unavailable !== "boolean" ||
    (value.task_title !== null && typeof value.task_title !== "string") ||
    (value.read_at !== null && !isTimestamp(value.read_at))
  ) {
    return null;
  }
  if (value.unavailable && value.task_title !== null) return null;

  return {
    id: value.id,
    occurred_at: value.occurred_at,
    actor_name: value.actor_name,
    reason_codes: [...new Set(value.reason_codes as TaskNotificationReason[])],
    task_title: value.task_title,
    unavailable: value.unavailable,
    read_at: value.read_at,
  };
}

export function parseTaskNotificationPage(
  value: unknown,
): TaskNotificationPage | null {
  if (!isRecord(value)) return null;
  if (value.status === "unavailable") return { status: "unavailable" };
  if (
    value.status !== "available" ||
    !Array.isArray(value.items) ||
    typeof value.unread_count !== "number" ||
    !Number.isSafeInteger(value.unread_count) ||
    value.unread_count < 0 ||
    typeof value.has_more !== "boolean" ||
    value.retention_days !== 90
  ) {
    return null;
  }
  const items = value.items.map(parseItem);
  const cursor =
    value.next_cursor === null ? null : parseCursor(value.next_cursor);
  if (
    items.some((item) => item === null) ||
    value.has_more !== (cursor !== null)
  ) {
    return null;
  }
  return {
    status: "available",
    items: items as TaskNotificationItem[],
    unread_count: value.unread_count,
    has_more: value.has_more,
    next_cursor: cursor,
    retention_days: 90,
  };
}

export function parseTaskNotificationTarget(
  value: unknown,
): TaskNotificationTarget | null {
  if (!isRecord(value)) return null;
  if (value.status === "unavailable") return { status: "unavailable" };
  if (
    value.status !== "available" ||
    typeof value.slug !== "string" ||
    !slugPattern.test(value.slug) ||
    typeof value.task_id !== "string" ||
    !uuidPattern.test(value.task_id) ||
    (value.comment_id !== null &&
      (typeof value.comment_id !== "string" ||
        !uuidPattern.test(value.comment_id)))
  ) {
    return null;
  }
  return {
    status: "available",
    slug: value.slug,
    task_id: value.task_id,
    comment_id: value.comment_id,
  };
}

export function buildTaskNotificationTargetHref(
  target: Extract<TaskNotificationTarget, { status: "available" }>,
): string | null {
  if (
    !slugPattern.test(target.slug) ||
    !uuidPattern.test(target.task_id) ||
    (target.comment_id !== null && !uuidPattern.test(target.comment_id))
  ) {
    return null;
  }
  const params = new URLSearchParams({ task: target.task_id });
  if (target.comment_id) params.set("comment", target.comment_id);
  const href = `/${encodeURIComponent(target.slug)}?${params.toString()}`;
  return target.comment_id ? `${href}#comment-${target.comment_id}` : href;
}

export type OpenTaskNotificationResult = "opened" | "unavailable" | "error";

export async function openTaskNotificationTarget(
  notificationId: string,
  resolveTarget: (id: string) => Promise<TaskNotificationTarget>,
  markRead: (id: string) => Promise<"confirmed" | "unavailable">,
  navigate: (href: string) => void,
): Promise<OpenTaskNotificationResult> {
  let target: TaskNotificationTarget;
  try {
    target = await resolveTarget(notificationId);
  } catch {
    return "error";
  }
  if (target.status !== "available") return "unavailable";
  const href = buildTaskNotificationTargetHref(target);
  if (!href) return "unavailable";

  try {
    const marked = await markRead(notificationId);
    if (marked !== "confirmed") return "unavailable";
  } catch {
    return "error";
  }
  navigate(href);
  return "opened";
}

export function taskNotificationReasonLabel(
  reasons: TaskNotificationReason[],
): string {
  if (reasons.includes("mention")) return "Te mencionaron en un comentario";
  if (reasons.includes("comment"))
    return "Nuevo comentario en una tarea asignada";
  if (reasons.includes("due_date"))
    return "Cambió el vencimiento de una tarea asignada";
  return "Te asignaron una tarea";
}

export function applyTaskNotificationRead(
  items: TaskNotificationItem[],
  notificationId: string,
  readAt: string,
  filter: "all" | "unread",
): TaskNotificationItem[] {
  if (filter === "unread") {
    return items.filter((item) => item.id !== notificationId);
  }
  return items.map((item) =>
    item.id === notificationId ? { ...item, read_at: readAt } : item,
  );
}

export function hideTaskNotificationTargets(
  items: TaskNotificationItem[],
): TaskNotificationItem[] {
  return items.map((item) => ({
    ...item,
    task_title: null,
    unavailable: true,
  }));
}
