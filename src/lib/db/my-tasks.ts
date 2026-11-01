import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  AssignableBoardMember,
  MyTaskEntry,
  MyTasksOrder,
  TaskAssigneeCommand,
  TaskAssigneeResult,
} from "@/lib/types";
import { taskAssigneeSchema } from "@/lib/validations";
import { isTaskRecord } from "./tasks";

export type TaskAssigneeErrorReason =
  | "rejected"
  | "conflict"
  | "access_denied"
  | "uncertain";

export class TaskAssigneeError extends Error {
  constructor(readonly reason: TaskAssigneeErrorReason) {
    super(reason);
    this.name = "TaskAssigneeError";
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isMyTaskEntry(value: unknown): value is MyTaskEntry {
  if (!isObject(value) || !isObject(value.task) || !isTaskRecord(value.task)) {
    return false;
  }
  if (!isObject(value.board) || !isObject(value.column)) return false;
  return (
    typeof value.board.id === "string" &&
    typeof value.board.slug === "string" &&
    typeof value.board.name === "string" &&
    typeof value.board.time_zone === "string" &&
    typeof value.board.today === "string" &&
    typeof value.column.id === "string" &&
    typeof value.column.title === "string" &&
    typeof value.column.position === "number"
  );
}

function isAssignableBoardMember(
  value: unknown,
): value is AssignableBoardMember {
  return (
    isObject(value) &&
    typeof value.user_id === "string" &&
    typeof value.email === "string" &&
    (value.role === "owner" || value.role === "collaborator")
  );
}

function isTaskAssigneeResult(value: unknown): value is TaskAssigneeResult {
  if (!isObject(value) || typeof value.operation_id !== "string") return false;
  if (
    (value.status === "confirmed" || value.status === "conflict") &&
    isTaskRecord(value.task)
  ) {
    return true;
  }
  return ["unavailable", "retryable", "expired_unknown"].includes(
    String(value.status),
  );
}

export async function getMyTasks(
  supabase: SupabaseClient,
  order: MyTasksOrder,
): Promise<MyTaskEntry[]> {
  const { data, error } = await supabase.rpc("get_my_tasks_p", {
    p_order: order,
  });
  if (error) throw error;
  if (!Array.isArray(data) || !data.every(isMyTaskEntry)) {
    throw new Error("The personal task response is invalid.");
  }
  return data;
}

export async function listAssignableBoardMembers(
  supabase: SupabaseClient,
  slug: string,
): Promise<AssignableBoardMember[]> {
  const { data, error } = await supabase.rpc(
    "list_assignable_board_members_p",
    { p_slug: slug },
  );
  if (error) throw error;
  if (!Array.isArray(data) || !data.every(isAssignableBoardMember)) {
    throw new Error("The board member response is invalid.");
  }
  return data;
}

export async function setTaskAssignee(
  supabase: SupabaseClient,
  slug: string,
  command: TaskAssigneeCommand,
): Promise<TaskAssigneeResult> {
  const parsed = taskAssigneeSchema.safeParse(command);
  if (!parsed.success) throw new TaskAssigneeError("rejected");

  const { data, error } = await supabase.rpc("set_task_assignee_p", {
    p_operation_id: parsed.data.operation_id,
    p_slug: slug,
    p_id: parsed.data.id,
    p_assignee_id: parsed.data.assignee_id,
    p_expected_version: parsed.data.expected_version,
  });
  if (error) {
    if (error.code === "42501") throw new TaskAssigneeError("access_denied");
    if (error.code === "22023") throw new TaskAssigneeError("rejected");
    if (error.code === "23514") throw new TaskAssigneeError("conflict");
    throw new TaskAssigneeError("uncertain");
  }
  if (
    !isTaskAssigneeResult(data) ||
    data.operation_id !== command.operation_id
  ) {
    throw new TaskAssigneeError("uncertain");
  }
  if (
    (data.status === "confirmed" || data.status === "conflict") &&
    data.task.id !== command.id
  ) {
    throw new TaskAssigneeError("conflict");
  }
  return data;
}
