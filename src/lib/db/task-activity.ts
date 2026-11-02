import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  TaskActivityActorType,
  TaskActivityCategory,
  TaskActivityCursor,
  TaskActivityEvent,
  TaskActivityPage,
} from "../types";

export class TaskActivityError extends Error {
  constructor() {
    super("No se pudo cargar la actividad de esta tarea.");
    this.name = "TaskActivityError";
  }
}

export interface TaskActivityPageRequest {
  limit: number;
  cursor: TaskActivityCursor | null;
}

const defaultPageRequest: TaskActivityPageRequest = {
  limit: 30,
  cursor: null,
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && Number.isFinite(Date.parse(value));
}

function parseCursor(value: unknown): TaskActivityCursor | null {
  if (!isRecord(value) || !isTimestamp(value.occurred_at)) return null;
  if (typeof value.id !== "string" || value.id.length === 0) return null;
  return { occurred_at: value.occurred_at, id: value.id };
}

function isActivityCategory(value: unknown): value is TaskActivityCategory {
  return (
    value === "assignee" ||
    value === "due_date" ||
    value === "column" ||
    value === "completion" ||
    value === "recovery"
  );
}

function isActorType(value: unknown): value is TaskActivityActorType {
  return value === "user" || value === "system" || value === "imported";
}

function isActivityValue(value: unknown): value is string | boolean | null {
  return (
    value === null || typeof value === "string" || typeof value === "boolean"
  );
}

function parseEvent(value: unknown): TaskActivityEvent | null {
  if (
    !isRecord(value) ||
    typeof value.id !== "string" ||
    !isActivityCategory(value.category) ||
    !isActorType(value.actor_type) ||
    !isTimestamp(value.occurred_at) ||
    !isActivityValue(value.before_value) ||
    !isActivityValue(value.after_value)
  ) {
    return null;
  }
  if (
    (value.actor_type === "system" && value.actor_name !== null) ||
    (value.actor_type !== "system" &&
      (typeof value.actor_name !== "string" || value.actor_name.trim() === ""))
  ) {
    return null;
  }
  if (
    value.category === "recovery" &&
    (value.before_value !== null || value.after_value !== null)
  ) {
    return null;
  }
  if (
    value.category !== "recovery" &&
    (value.before_value === null || value.after_value === null) &&
    value.category !== "due_date"
  ) {
    return null;
  }
  return {
    id: value.id,
    category: value.category,
    actor_type: value.actor_type,
    actor_name: typeof value.actor_name === "string" ? value.actor_name : null,
    occurred_at: value.occurred_at,
    before_value: value.before_value,
    after_value: value.after_value,
  };
}

export function parseTaskActivityPage(value: unknown): TaskActivityPage | null {
  if (!isRecord(value)) return null;
  if (value.status === "unavailable") return { status: "unavailable" };
  if (
    value.status !== "available" ||
    !Array.isArray(value.events) ||
    typeof value.has_more !== "boolean" ||
    value.retention_days !== 180
  ) {
    return null;
  }
  const events = value.events.map(parseEvent);
  if (events.some((event) => event === null)) return null;
  const cursor =
    value.next_cursor === null ? null : parseCursor(value.next_cursor);
  if (value.has_more !== (cursor !== null)) return null;
  return {
    status: "available",
    events: events as TaskActivityEvent[],
    has_more: value.has_more,
    next_cursor: cursor,
    retention_days: 180,
  };
}

export async function listTaskActivity(
  supabase: SupabaseClient,
  slug: string,
  taskId: string,
  request: Partial<TaskActivityPageRequest> = {},
): Promise<TaskActivityPage> {
  const pageRequest = { ...defaultPageRequest, ...request };
  if (
    !slug ||
    !taskId ||
    !Number.isSafeInteger(pageRequest.limit) ||
    pageRequest.limit < 1 ||
    pageRequest.limit > 100 ||
    (pageRequest.cursor !== null && !parseCursor(pageRequest.cursor as unknown))
  ) {
    throw new TaskActivityError();
  }

  let response: Awaited<ReturnType<SupabaseClient["rpc"]>>;
  try {
    response = await supabase.rpc("get_task_activity_p", {
      p_slug: slug,
      p_task_id: taskId,
      p_limit: pageRequest.limit,
      p_before_occurred_at: pageRequest.cursor?.occurred_at ?? null,
      p_before_id: pageRequest.cursor?.id ?? null,
    });
  } catch {
    throw new TaskActivityError();
  }
  if (response.error) throw new TaskActivityError();
  const page = parseTaskActivityPage(response.data);
  if (!page) throw new TaskActivityError();
  return page;
}
