import type { TaskNotificationItem } from "./task-notification-state.ts";

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type TaskNotificationBatchItemResult = {
  id: string;
  result: "marked" | "already_read" | "unavailable" | "failed";
};

export type TaskNotificationBatchResult = {
  status: "confirmed";
  operation_id: string;
  items: TaskNotificationBatchItemResult[];
};

export type TaskNotificationBatchCheckResult =
  | TaskNotificationBatchResult
  | { status: "expired_unknown"; operation_id: string }
  | { status: "not_found"; operation_id: string }
  | { status: "unavailable"; operation_id: string }
  | { status: "processing"; operation_id: string };

export type TaskNotificationBatchAttempt =
  | TaskNotificationBatchCheckResult
  | { status: "uncertain"; operation_id: string };

export type TaskNotificationBatchOperation = {
  operationId: string;
  notificationIds: string[];
  retryFailed: boolean;
};

export interface TaskNotificationBatchApi {
  mark(
    operationId: string,
    notificationIds: string[],
    retryFailed: boolean,
  ): Promise<TaskNotificationBatchCheckResult>;
  get(
    operationId: string,
    notificationIds: string[],
  ): Promise<TaskNotificationBatchCheckResult>;
}

export interface TaskNotificationBatchSummary {
  marked: number;
  already_read: number;
  unavailable: number;
  failed: number;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function snapshotLoadedUnreadTaskNotificationIds(
  items: TaskNotificationItem[],
): string[] {
  const seen = new Set<string>();
  const ids: string[] = [];
  for (const item of items) {
    if (
      item.read_at === null &&
      uuidPattern.test(item.id) &&
      !seen.has(item.id)
    ) {
      seen.add(item.id);
      ids.push(item.id);
    }
  }
  return ids;
}

export function summarizeTaskNotificationBatch(
  result: TaskNotificationBatchResult,
): TaskNotificationBatchSummary {
  return result.items.reduce<TaskNotificationBatchSummary>(
    (summary, item) => {
      summary[item.result] += 1;
      return summary;
    },
    { marked: 0, already_read: 0, unavailable: 0, failed: 0 },
  );
}

export function applyTaskNotificationBatchResults(
  items: TaskNotificationItem[],
  results: TaskNotificationBatchItemResult[],
  readAt: string,
  filter: "all" | "unread",
): TaskNotificationItem[] {
  let nextItems = items;
  for (const result of results) {
    if (result.result === "marked" || result.result === "already_read") {
      nextItems = nextItems
        .filter((item) => item.id !== result.id || filter !== "unread")
        .map((item) =>
          item.id === result.id ? { ...item, read_at: readAt } : item,
        );
    } else if (result.result === "unavailable") {
      nextItems =
        filter === "unread"
          ? nextItems.filter((item) => item.id !== result.id)
          : nextItems.map((item) =>
              item.id === result.id
                ? { ...item, task_title: null, unavailable: true }
                : item,
            );
    }
  }
  return nextItems;
}

export function parseTaskNotificationBatchResult(
  value: unknown,
  expectedOperationId: string,
  expectedIds: string[],
): TaskNotificationBatchResult | null {
  if (
    !isRecord(value) ||
    value.status !== "confirmed" ||
    value.operation_id !== expectedOperationId ||
    !Array.isArray(value.items)
  ) {
    return null;
  }

  const expected = new Set(expectedIds);
  if (
    expected.size !== expectedIds.length ||
    value.items.length !== expected.size
  ) {
    return null;
  }
  const seen = new Set<string>();
  const items: TaskNotificationBatchItemResult[] = [];
  for (const item of value.items) {
    if (
      !isRecord(item) ||
      typeof item.id !== "string" ||
      !uuidPattern.test(item.id) ||
      !expected.has(item.id) ||
      seen.has(item.id) ||
      !["marked", "already_read", "unavailable", "failed"].includes(
        String(item.result),
      )
    ) {
      return null;
    }
    seen.add(item.id);
    items.push({
      id: item.id,
      result: item.result as TaskNotificationBatchItemResult["result"],
    });
  }

  return seen.size === expected.size
    ? { status: "confirmed", operation_id: expectedOperationId, items }
    : null;
}

export function parseTaskNotificationBatchCheckResult(
  value: unknown,
  expectedOperationId: string,
  expectedIds: string[],
): TaskNotificationBatchCheckResult | null {
  if (!isRecord(value)) return null;
  if (value.status === "confirmed") {
    return parseTaskNotificationBatchResult(
      value,
      expectedOperationId,
      expectedIds,
    );
  }
  if (
    !["expired_unknown", "not_found", "unavailable", "processing"].includes(
      String(value.status),
    ) ||
    (value.operation_id !== undefined &&
      value.operation_id !== expectedOperationId) ||
    (value.status !== "unavailable" &&
      value.operation_id !== expectedOperationId)
  ) {
    return null;
  }
  return {
    status: value.status as Exclude<
      TaskNotificationBatchCheckResult["status"],
      "confirmed"
    >,
    operation_id: expectedOperationId,
  };
}

export function acquireTaskNotificationBatchLock(lock: {
  current: boolean;
}): boolean {
  if (lock.current) return false;
  lock.current = true;
  return true;
}

export function releaseTaskNotificationBatchLock(lock: {
  current: boolean;
}): void {
  lock.current = false;
}

async function reconcileAfterUncertainResponse(
  operation: TaskNotificationBatchOperation,
  api: TaskNotificationBatchApi,
): Promise<TaskNotificationBatchAttempt> {
  let receipt: TaskNotificationBatchCheckResult;
  try {
    receipt = await api.get(operation.operationId, operation.notificationIds);
  } catch {
    return { status: "uncertain", operation_id: operation.operationId };
  }
  if (receipt.status !== "not_found") return receipt;
  try {
    // A missing receipt from GET can race with the original RPC transaction.
    // Calling mark with the same operation serializes on the receipt key: it
    // either recovers the committed receipt or returns an inert not_found.
    return await api.mark(
      operation.operationId,
      operation.notificationIds,
      operation.retryFailed,
    );
  } catch {
    return { status: "uncertain", operation_id: operation.operationId };
  }
}

export async function runTaskNotificationBatch(
  operation: TaskNotificationBatchOperation,
  api: TaskNotificationBatchApi,
): Promise<TaskNotificationBatchAttempt> {
  try {
    return await api.mark(
      operation.operationId,
      operation.notificationIds,
      operation.retryFailed,
    );
  } catch {
    return reconcileAfterUncertainResponse(operation, api);
  }
}

export function checkTaskNotificationBatch(
  operation: TaskNotificationBatchOperation,
  api: TaskNotificationBatchApi,
): Promise<TaskNotificationBatchAttempt> {
  return reconcileAfterUncertainResponse(operation, api);
}
