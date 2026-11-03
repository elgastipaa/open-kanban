import type { SupabaseClient } from "@supabase/supabase-js";
import {
  parseTaskNotificationBatchCheckResult,
  type TaskNotificationBatchCheckResult,
} from "@/lib/task-notification-batch-state";
import {
  parseTaskNotificationPage,
  parseTaskNotificationTarget,
  type TaskNotificationCursor,
  type TaskNotificationPage,
  type TaskNotificationTarget,
} from "@/lib/task-notification-state";

export type TaskNotificationFilter = "all" | "unread";

export class TaskNotificationError extends Error {
  constructor() {
    super("No se pudieron cargar las novedades.");
    this.name = "TaskNotificationError";
  }
}

export class TaskNotificationBatchError extends Error {
  constructor() {
    super("No se pudo confirmar el lote de novedades.");
    this.name = "TaskNotificationBatchError";
  }
}

const notificationIdPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function validateBatch(operationId: string, notificationIds: string[]): void {
  if (
    !notificationIdPattern.test(operationId) ||
    notificationIds.length < 1 ||
    notificationIds.length > 100 ||
    notificationIds.some((id) => !notificationIdPattern.test(id)) ||
    new Set(notificationIds).size !== notificationIds.length
  ) {
    throw new TaskNotificationBatchError();
  }
}

function parseBatchResponse(
  data: unknown,
  operationId: string,
  notificationIds: string[],
): TaskNotificationBatchCheckResult {
  const result = parseTaskNotificationBatchCheckResult(
    data,
    operationId,
    notificationIds,
  );
  if (!result) throw new TaskNotificationBatchError();
  return result;
}

export async function markMyTaskNotificationsBatch(
  supabase: SupabaseClient,
  operationId: string,
  notificationIds: string[],
  retryFailed = false,
): Promise<TaskNotificationBatchCheckResult> {
  validateBatch(operationId, notificationIds);
  if (typeof retryFailed !== "boolean") throw new TaskNotificationBatchError();
  const { data, error } = await supabase.rpc(
    "mark_my_task_notifications_batch_p",
    {
      p_operation_id: operationId,
      p_notification_ids: notificationIds,
      p_retry_failed: retryFailed,
    },
  );
  if (error) throw new TaskNotificationBatchError();
  return parseBatchResponse(data, operationId, notificationIds);
}

export async function getMyTaskNotificationBatch(
  supabase: SupabaseClient,
  operationId: string,
  notificationIds: string[],
): Promise<TaskNotificationBatchCheckResult> {
  validateBatch(operationId, notificationIds);
  const { data, error } = await supabase.rpc(
    "get_my_task_notification_batch_p",
    { p_operation_id: operationId },
  );
  if (error) throw new TaskNotificationBatchError();
  return parseBatchResponse(data, operationId, notificationIds);
}

export async function listMyTaskNotifications(
  supabase: SupabaseClient,
  filter: TaskNotificationFilter = "all",
  limit = 30,
  cursor: TaskNotificationCursor | null = null,
): Promise<TaskNotificationPage> {
  if (
    (filter !== "all" && filter !== "unread") ||
    !Number.isSafeInteger(limit) ||
    limit < 1 ||
    limit > 100 ||
    (cursor !== null &&
      (!Number.isFinite(Date.parse(cursor.occurred_at)) ||
        !/^[0-9a-f-]{36}$/i.test(cursor.id)))
  ) {
    throw new TaskNotificationError();
  }
  const { data, error } = await supabase.rpc("list_my_task_notifications_p", {
    p_filter: filter,
    p_limit: limit,
    p_before_occurred_at: cursor?.occurred_at ?? null,
    p_before_id: cursor?.id ?? null,
  });
  if (error) throw new TaskNotificationError();
  const page = parseTaskNotificationPage(data);
  if (!page) throw new TaskNotificationError();
  return page;
}

export async function getMyTaskNotificationTarget(
  supabase: SupabaseClient,
  notificationId: string,
): Promise<TaskNotificationTarget> {
  if (!/^[0-9a-f-]{36}$/i.test(notificationId)) {
    throw new TaskNotificationError();
  }
  const { data, error } = await supabase.rpc(
    "get_my_task_notification_target_p",
    { p_notification_id: notificationId },
  );
  if (error) throw new TaskNotificationError();
  const target = parseTaskNotificationTarget(data);
  if (!target) throw new TaskNotificationError();
  return target;
}

export async function markMyTaskNotificationRead(
  supabase: SupabaseClient,
  notificationId: string,
): Promise<"confirmed" | "unavailable"> {
  if (!/^[0-9a-f-]{36}$/i.test(notificationId)) {
    throw new TaskNotificationError();
  }
  const { data, error } = await supabase.rpc(
    "mark_my_task_notification_read_p",
    { p_notification_id: notificationId },
  );
  if (error) throw new TaskNotificationError();
  if (
    typeof data !== "object" ||
    data === null ||
    !("status" in data) ||
    (data.status !== "confirmed" && data.status !== "unavailable")
  ) {
    throw new TaskNotificationError();
  }
  return data.status;
}
