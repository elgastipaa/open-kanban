import type { SupabaseClient } from "@supabase/supabase-js";
import { isDateOnly } from "@/lib/task-date";
import type {
  BoardState,
  CreateTaskPayload,
  Task,
  TaskCompletionCommand,
  TaskCompletionResult,
  TaskEditConflicts,
  TaskEditResult,
  TaskOrderColumnSnapshot,
  TaskOrderCommand,
  TaskOrderResult,
  UpdateTaskPayload,
} from "@/lib/types";
import { createTaskSchema, updateTaskSchema } from "@/lib/validations";
import { taskCaptureErrorReasonFromCode } from "../task-capture-state";
import { handleSupabaseError } from "./errors";

export type TaskCaptureStatus =
  | "confirmed"
  | "not_found"
  | "expired_unknown"
  | "unavailable";

interface TaskCaptureResult {
  status: TaskCaptureStatus;
  operation_id?: string;
  board_id?: string;
  column_id?: string;
  task_id?: string;
  task?: Task;
}

export type TaskCaptureErrorReason =
  | "uncertain"
  | "expired_unknown"
  | "unavailable"
  | "rejected"
  | "conflict"
  | "access_denied";

export class TaskCaptureError extends Error {
  constructor(readonly reason: TaskCaptureErrorReason) {
    super(reason);
    this.name = "TaskCaptureError";
  }
}

export type TaskEditErrorReason =
  | "uncertain"
  | "retryable"
  | "expired_unknown"
  | "unavailable"
  | "rejected"
  | "conflict"
  | "access_denied"
  | "stale_session";

export class TaskEditError extends Error {
  constructor(readonly reason: TaskEditErrorReason) {
    super(reason);
    this.name = "TaskEditError";
  }
}

export type TaskCompletionErrorReason =
  | "uncertain"
  | "expired_unknown"
  | "retryable"
  | "unavailable"
  | "rejected"
  | "conflict"
  | "access_denied";

export class TaskCompletionError extends Error {
  constructor(readonly reason: TaskCompletionErrorReason) {
    super(reason);
    this.name = "TaskCompletionError";
  }
}

export type TaskOrderErrorReason =
  | "uncertain"
  | "retryable"
  | "expired_unknown"
  | "unavailable"
  | "rejected"
  | "access_denied";

export class TaskOrderError extends Error {
  constructor(readonly reason: TaskOrderErrorReason) {
    super(reason);
    this.name = "TaskOrderError";
  }
}

export interface TaskRecoveryItem {
  task_id: string;
  title: string;
  original_column_id: string;
  cause: string;
  deleted_at: string;
  expires_at: string;
  can_restore: boolean;
  original_column_available: boolean;
  eligibility_checked_at: string;
}

export type TaskRecoveryResultStatus =
  | "confirmed"
  | "needs_destination"
  | "expired"
  | "unavailable";

export interface TaskRecoveryResult {
  status: TaskRecoveryResultStatus;
  operation_id: string;
}

export type TaskRecoveryErrorReason =
  | "uncertain"
  | "unavailable"
  | "expired"
  | "rejected"
  | "access_denied";

export class TaskRecoveryError extends Error {
  constructor(readonly reason: TaskRecoveryErrorReason) {
    super(reason);
    this.name = "TaskRecoveryError";
  }
}

function isTaskCaptureResult(value: unknown): value is TaskCaptureResult {
  return (
    typeof value === "object" &&
    value !== null &&
    "status" in value &&
    ["confirmed", "not_found", "expired_unknown", "unavailable"].includes(
      String(value.status),
    )
  );
}

function throwForResult(result: TaskCaptureResult): never {
  if (result.status === "expired_unknown") {
    throw new TaskCaptureError("expired_unknown");
  }
  if (result.status === "unavailable") {
    throw new TaskCaptureError("unavailable");
  }
  throw new TaskCaptureError("uncertain");
}

function taskFromResult(
  result: TaskCaptureResult,
  operationId: string,
  boardId: string,
): Task {
  if (result.status !== "confirmed" || !result.task) {
    throwForResult(result);
  }
  if (
    result.operation_id !== operationId ||
    result.board_id !== boardId ||
    result.task.id !== result.task_id
  ) {
    throw new TaskCaptureError("conflict");
  }
  return result.task;
}

async function queryTaskCreationResult(
  supabase: SupabaseClient,
  operationId: string,
  boardId: string,
  payload: CreateTaskPayload,
): Promise<TaskCaptureResult> {
  const { data, error } = await supabase.rpc("get_task_creation_result_p", {
    p_operation_id: operationId,
    p_board_id: boardId,
    p_column_id: payload.column_id,
    p_title: payload.title,
    p_description: payload.description ?? null,
    p_priority: payload.priority ?? "medium",
  });
  if (error) {
    throw definiteFailure(error) ?? new TaskCaptureError("uncertain");
  }
  if (!isTaskCaptureResult(data)) {
    throw new TaskCaptureError("uncertain");
  }
  return data;
}

async function resolveExpiredTaskCreation(
  supabase: SupabaseClient,
  slug: string,
  operationId: string,
  boardId: string,
  payload: CreateTaskPayload,
): Promise<Task> {
  const result = await queryTaskCreationResult(
    supabase,
    operationId,
    boardId,
    payload,
  );
  if (result.status !== "expired_unknown") throwForResult(result);
  if (
    result.operation_id !== operationId ||
    result.board_id !== boardId ||
    !result.task_id
  ) {
    throw new TaskCaptureError("conflict");
  }

  const response = await supabase
    .rpc("get_full_board_p", { p_slug: slug })
    .maybeSingle();
  if (response.error) {
    const accessDenied = definiteFailure(response.error);
    if (accessDenied?.reason === "access_denied") throw accessDenied;
    throw new TaskCaptureError("expired_unknown");
  }
  if (!response.data) {
    throw new TaskCaptureError("expired_unknown");
  }

  const boardState = response.data as BoardState;
  if (boardState.board?.id !== boardId) {
    throw new TaskCaptureError("unavailable");
  }
  const task = boardState.columns
    .flatMap((column) => column.tasks)
    .find((candidate) => candidate.id === result.task_id);
  if (!task) {
    throw new TaskCaptureError("expired_unknown");
  }
  return task;
}

async function taskAfterResult(
  supabase: SupabaseClient,
  slug: string,
  operationId: string,
  boardId: string,
  payload: CreateTaskPayload,
  result: TaskCaptureResult,
): Promise<Task> {
  if (result.status === "expired_unknown") {
    return resolveExpiredTaskCreation(
      supabase,
      slug,
      operationId,
      boardId,
      payload,
    );
  }
  return taskFromResult(result, operationId, boardId);
}

function definiteFailure(error: unknown): TaskCaptureError | null {
  const code =
    typeof error === "object" && error !== null && "code" in error
      ? String(error.code)
      : "";
  const reason = taskCaptureErrorReasonFromCode(code);
  return reason ? new TaskCaptureError(reason) : null;
}

async function invokeCreateTask(
  supabase: SupabaseClient,
  operationId: string,
  boardId: string,
  payload: CreateTaskPayload,
): Promise<TaskCaptureResult> {
  const { data, error } = await supabase.rpc("create_task_p", {
    p_operation_id: operationId,
    p_board_id: boardId,
    p_column_id: payload.column_id,
    p_title: payload.title,
    p_description: payload.description ?? null,
    p_priority: payload.priority ?? "medium",
  });
  if (error) throw error;
  if (!isTaskCaptureResult(data)) throw new TaskCaptureError("uncertain");
  return data;
}

async function reconcileAfterCreateFailure(
  supabase: SupabaseClient,
  slug: string,
  operationId: string,
  boardId: string,
  payload: CreateTaskPayload,
): Promise<Task> {
  const priorResult = await queryTaskCreationResult(
    supabase,
    operationId,
    boardId,
    payload,
  );
  if (priorResult.status !== "not_found") {
    return taskAfterResult(
      supabase,
      slug,
      operationId,
      boardId,
      payload,
      priorResult,
    );
  }

  // The server confirmed there is no receipt, so retry exactly once with the
  // same operation id and payload. Never mint a replacement intent here.
  try {
    const retryResult = await invokeCreateTask(
      supabase,
      operationId,
      boardId,
      payload,
    );
    if (retryResult.status === "not_found") {
      throw new TaskCaptureError("uncertain");
    }
    return taskAfterResult(
      supabase,
      slug,
      operationId,
      boardId,
      payload,
      retryResult,
    );
  } catch (retryError) {
    if (
      retryError instanceof TaskCaptureError &&
      retryError.reason !== "uncertain"
    ) {
      throw retryError;
    }
    const definite = definiteFailure(retryError);
    if (definite) throw definite;

    const finalResult = await queryTaskCreationResult(
      supabase,
      operationId,
      boardId,
      payload,
    );
    if (finalResult.status === "not_found") {
      throw new TaskCaptureError("uncertain");
    }
    return taskAfterResult(
      supabase,
      slug,
      operationId,
      boardId,
      payload,
      finalResult,
    );
  }
}

/** Fetch all tasks for a board (via its columns), ordered by position */
export async function getTasksByBoard(
  supabase: SupabaseClient,
  boardId: string,
): Promise<Task[]> {
  const response = await supabase.rpc("get_tasks_by_board_p", {
    p_board_id: boardId,
  });

  if (response.error) handleSupabaseError(response.error);
  return (response.data as Task[]) ?? [];
}

/** Create a new task (slug-scoped — Finding #7) */
export async function createTask(
  supabase: SupabaseClient,
  slug: string,
  operationId: string,
  boardId: string,
  payload: CreateTaskPayload,
): Promise<Task> {
  let parsed: CreateTaskPayload;
  try {
    parsed = createTaskSchema.parse(payload);
  } catch {
    throw new TaskCaptureError("rejected");
  }
  let result: TaskCaptureResult;
  try {
    result = await invokeCreateTask(supabase, operationId, boardId, parsed);
  } catch (error) {
    const definite = definiteFailure(error);
    if (definite) throw definite;
    return reconcileAfterCreateFailure(
      supabase,
      slug,
      operationId,
      boardId,
      parsed,
    );
  }
  if (result.status === "not_found") {
    return reconcileAfterCreateFailure(
      supabase,
      slug,
      operationId,
      boardId,
      parsed,
    );
  }
  return taskAfterResult(supabase, slug, operationId, boardId, parsed, result);
}

/** Query a prior explicit capture, retrying only after a not-found receipt. */
export async function reconcileTaskCreation(
  supabase: SupabaseClient,
  slug: string,
  operationId: string,
  boardId: string,
  payload: CreateTaskPayload,
): Promise<Task> {
  let parsed: CreateTaskPayload;
  try {
    parsed = createTaskSchema.parse(payload);
  } catch {
    throw new TaskCaptureError("rejected");
  }
  const result = await queryTaskCreationResult(
    supabase,
    operationId,
    boardId,
    parsed,
  );
  if (result.status === "not_found") {
    return reconcileAfterCreateFailure(
      supabase,
      slug,
      operationId,
      boardId,
      parsed,
    );
  }
  return taskAfterResult(supabase, slug, operationId, boardId, parsed, result);
}

/** Update only explicitly supplied task fields; null clears description. */
export async function updateTask(
  supabase: SupabaseClient,
  slug: string,
  payload: UpdateTaskPayload,
): Promise<TaskEditResult> {
  try {
    updateTaskSchema.parse(payload);
  } catch {
    throw new TaskEditError("rejected");
  }

  const response = await supabase.rpc("edit_task_fields_p", {
    p_operation_id: payload.operation_id,
    p_slug: slug,
    p_id: payload.id,
    p_updates: payload.updates,
    p_expected_versions: payload.expected_versions,
  });

  if (response.error) {
    if (response.error.code === "42501") {
      throw new TaskEditError("access_denied");
    }
    if (response.error.code === "22023") {
      throw new TaskEditError("rejected");
    }
    if (response.error.code === "23514") {
      throw new TaskEditError("conflict");
    }
    throw new TaskEditError("uncertain");
  }

  if (!isTaskEditResult(response.data)) {
    throw new TaskEditError("uncertain");
  }
  if (response.data.operation_id !== payload.operation_id) {
    throw new TaskEditError("conflict");
  }
  if (
    (response.data.status === "confirmed" ||
      response.data.status === "conflict") &&
    response.data.task.id !== payload.id
  ) {
    throw new TaskEditError("conflict");
  }
  if (
    response.data.status === "unavailable" ||
    response.data.status === "retryable" ||
    response.data.status === "expired_unknown"
  ) {
    throw new TaskEditError(response.data.status);
  }
  return response.data;
}

/** Set a task's desired completion state with a versioned idempotent command. */
export async function setTaskCompletion(
  supabase: SupabaseClient,
  slug: string,
  command: TaskCompletionCommand,
): Promise<TaskCompletionResult> {
  if (
    !command.id ||
    !command.operation_id ||
    typeof command.is_completed !== "boolean" ||
    !Number.isInteger(command.expected_version) ||
    command.expected_version < 1
  ) {
    throw new TaskCompletionError("rejected");
  }

  const response = await supabase.rpc("set_task_completion_p", {
    p_operation_id: command.operation_id,
    p_slug: slug,
    p_id: command.id,
    p_is_completed: command.is_completed,
    p_expected_version: command.expected_version,
  });

  if (response.error) {
    if (response.error.code === "42501") {
      throw new TaskCompletionError("access_denied");
    }
    if (response.error.code === "22023") {
      throw new TaskCompletionError("rejected");
    }
    if (response.error.code === "23514") {
      throw new TaskCompletionError("conflict");
    }
    throw new TaskCompletionError("uncertain");
  }

  if (!isTaskCompletionResult(response.data)) {
    throw new TaskCompletionError("uncertain");
  }
  if (response.data.operation_id !== command.operation_id) {
    throw new TaskCompletionError("conflict");
  }
  if (
    (response.data.status === "confirmed" ||
      response.data.status === "conflict") &&
    response.data.task.id !== command.id
  ) {
    throw new TaskCompletionError("conflict");
  }
  if (
    response.data.status === "unavailable" ||
    response.data.status === "retryable" ||
    response.data.status === "expired_unknown"
  ) {
    throw new TaskCompletionError(response.data.status);
  }
  return response.data;
}

function isTaskCompletionResult(value: unknown): value is TaskCompletionResult {
  if (
    typeof value !== "object" ||
    value === null ||
    !("status" in value) ||
    !("operation_id" in value) ||
    typeof value.operation_id !== "string"
  ) {
    return false;
  }
  if (value.status === "confirmed" || value.status === "conflict") {
    return "task" in value && isTaskRecord(value.task);
  }
  return ["unavailable", "retryable", "expired_unknown"].includes(
    String(value.status),
  );
}

function isTaskEditResult(value: unknown): value is TaskEditResult {
  if (typeof value !== "object" || value === null || !("status" in value)) {
    return false;
  }
  if (!("operation_id" in value) || typeof value.operation_id !== "string") {
    return false;
  }
  if (value.status === "confirmed") {
    return "task" in value && isTaskRecord(value.task);
  }
  if (value.status === "conflict") {
    return (
      "task" in value &&
      isTaskRecord(value.task) &&
      "conflicts" in value &&
      isTaskEditConflicts(value.conflicts)
    );
  }
  return ["unavailable", "retryable", "expired_unknown"].includes(
    String(value.status),
  );
}

export function isTaskRecord(value: unknown): value is Task {
  if (typeof value !== "object" || value === null || !("id" in value)) {
    return false;
  }
  if (
    !("field_versions" in value) ||
    typeof value.field_versions !== "object" ||
    value.field_versions === null
  ) {
    return false;
  }
  const versions = value.field_versions as Record<string, unknown>;
  return (
    "assignee_id" in value &&
    (typeof value.assignee_id === "string" || value.assignee_id === null) &&
    "assignee_version" in value &&
    typeof value.assignee_version === "number" &&
    value.assignee_version > 0 &&
    ["title", "description", "priority", "due_on"].every(
      (field) => typeof versions[field] === "number",
    ) &&
    "due_on" in value &&
    (typeof value.due_on === "string"
      ? isDateOnly(value.due_on)
      : value.due_on === null) &&
    "is_completed" in value &&
    typeof value.is_completed === "boolean" &&
    "completed_at" in value &&
    (typeof value.completed_at === "string" || value.completed_at === null) &&
    "completion_version" in value &&
    typeof value.completion_version === "number" &&
    value.completion_version > 0
  );
}

function isTaskEditConflicts(value: unknown): value is TaskEditConflicts {
  if (typeof value !== "object" || value === null) return false;
  return Object.values(value).every(
    (conflict) =>
      typeof conflict === "object" &&
      conflict !== null &&
      "current_version" in conflict &&
      typeof conflict.current_version === "number",
  );
}

function isTaskOrderColumnSnapshot(
  value: unknown,
): value is TaskOrderColumnSnapshot {
  return (
    typeof value === "object" &&
    value !== null &&
    "id" in value &&
    typeof value.id === "string" &&
    "task_order_version" in value &&
    typeof value.task_order_version === "number" &&
    "tasks" in value &&
    Array.isArray(value.tasks) &&
    value.tasks.every(isTaskRecord)
  );
}

function isTaskOrderResult(value: unknown): value is TaskOrderResult {
  if (
    typeof value !== "object" ||
    value === null ||
    !("status" in value) ||
    !("operation_id" in value) ||
    typeof value.operation_id !== "string"
  ) {
    return false;
  }
  if (value.status === "confirmed" || value.status === "conflict") {
    return (
      "columns" in value &&
      Array.isArray(value.columns) &&
      value.columns.every(isTaskOrderColumnSnapshot)
    );
  }
  return [
    "retryable",
    "expired_unknown",
    "uncertain",
    "unavailable",
    "rejected",
    "access_denied",
  ].includes(String(value.status));
}

function isTaskRecoveryItem(value: unknown): value is TaskRecoveryItem {
  return (
    typeof value === "object" &&
    value !== null &&
    "task_id" in value &&
    typeof value.task_id === "string" &&
    "title" in value &&
    typeof value.title === "string" &&
    "original_column_id" in value &&
    typeof value.original_column_id === "string" &&
    "cause" in value &&
    typeof value.cause === "string" &&
    "deleted_at" in value &&
    typeof value.deleted_at === "string" &&
    "expires_at" in value &&
    typeof value.expires_at === "string" &&
    "can_restore" in value &&
    typeof value.can_restore === "boolean" &&
    "original_column_available" in value &&
    typeof value.original_column_available === "boolean" &&
    "eligibility_checked_at" in value &&
    typeof value.eligibility_checked_at === "string"
  );
}

function isTaskRecoveryResult(value: unknown): value is TaskRecoveryResult {
  return (
    typeof value === "object" &&
    value !== null &&
    "status" in value &&
    ["confirmed", "needs_destination", "expired", "unavailable"].includes(
      String(value.status),
    ) &&
    "operation_id" in value &&
    typeof value.operation_id === "string"
  );
}

function taskRecoveryErrorForCode(code: string): TaskRecoveryError | null {
  if (code === "42501") return new TaskRecoveryError("access_denied");
  if (code === "22023" || code === "22P02" || code === "23514") {
    return new TaskRecoveryError("rejected");
  }
  return null;
}

/** Load only the current member's deleted tasks for this board. */
export async function listDeletedTasks(
  supabase: SupabaseClient,
  slug: string,
): Promise<TaskRecoveryItem[]> {
  const { data, error } = await supabase.rpc("list_deleted_tasks_p", {
    p_slug: slug,
  });
  if (error) {
    throw (
      taskRecoveryErrorForCode(error.code ?? "") ??
      new TaskRecoveryError("uncertain")
    );
  }
  if (!Array.isArray(data) || !data.every(isTaskRecoveryItem)) {
    throw new TaskRecoveryError("uncertain");
  }
  return data;
}

/**
 * Delete with a durable operation id. Repeating one intent reconciles a lost
 * response instead of issuing a second deletion command.
 */
export async function deleteTask(
  supabase: SupabaseClient,
  slug: string,
  operationId: string,
  taskId: string,
): Promise<void> {
  if (!operationId || !taskId || !slug) {
    throw new TaskRecoveryError("rejected");
  }
  for (let attempt = 0; attempt < 2; attempt += 1) {
    let response: Awaited<ReturnType<SupabaseClient["rpc"]>>;
    try {
      response = await supabase.rpc("delete_task_p", {
        p_operation_id: operationId,
        p_slug: slug,
        p_id: taskId,
        p_cause: "user_requested",
      });
    } catch {
      if (attempt === 1) throw new TaskRecoveryError("uncertain");
      continue;
    }
    if (response.error) {
      const definite = taskRecoveryErrorForCode(response.error.code ?? "");
      if (definite) throw definite;
      if (attempt === 1) throw new TaskRecoveryError("uncertain");
      continue;
    }
    if (!isTaskRecoveryResult(response.data)) {
      throw new TaskRecoveryError("uncertain");
    }
    if (response.data.operation_id !== operationId) {
      throw new TaskRecoveryError("uncertain");
    }
    if (response.data.status === "confirmed") return;
    if (response.data.status === "expired") {
      throw new TaskRecoveryError("expired");
    }
    throw new TaskRecoveryError("unavailable");
  }
  throw new TaskRecoveryError("uncertain");
}

/** Restore with the same operation key when reconciling a lost response. */
export async function restoreTask(
  supabase: SupabaseClient,
  slug: string,
  operationId: string,
  taskId: string,
  targetColumnId: string | null,
): Promise<TaskRecoveryResult> {
  if (!operationId || !taskId || !slug) {
    throw new TaskRecoveryError("rejected");
  }
  for (let attempt = 0; attempt < 2; attempt += 1) {
    let response: Awaited<ReturnType<SupabaseClient["rpc"]>>;
    try {
      response = await supabase.rpc("restore_task_p", {
        p_operation_id: operationId,
        p_slug: slug,
        p_id: taskId,
        p_target_column_id: targetColumnId,
      });
    } catch {
      if (attempt === 1) throw new TaskRecoveryError("uncertain");
      continue;
    }
    if (response.error) {
      const definite = taskRecoveryErrorForCode(response.error.code ?? "");
      if (definite) throw definite;
      if (attempt === 1) throw new TaskRecoveryError("uncertain");
      continue;
    }
    if (!isTaskRecoveryResult(response.data)) {
      throw new TaskRecoveryError("uncertain");
    }
    if (response.data.operation_id !== operationId) {
      throw new TaskRecoveryError("uncertain");
    }
    return response.data;
  }
  throw new TaskRecoveryError("uncertain");
}

/** Maximum batch size for position updates (Finding #4) */
const MAX_BATCH_SIZE = 200;

/** Apply a retry-safe, versioned ordering command. */
export async function updateTaskPositions(
  supabase: SupabaseClient,
  slug: string,
  command: TaskOrderCommand,
): Promise<TaskOrderResult> {
  if (command.moves.length === 0) {
    return { status: "rejected", operation_id: command.operation_id };
  }
  if (command.moves.length > MAX_BATCH_SIZE) {
    throw new TaskOrderError("rejected");
  }
  const { data, error } = await supabase.rpc("update_task_positions_p", {
    p_operation_id: command.operation_id,
    p_slug: slug,
    p_moves: command.moves,
    p_expected_order_versions: command.expected_order_versions,
  });
  if (error) {
    console.error("[Supabase Error]", error);
    if (error.code === "42501") throw new TaskOrderError("access_denied");
    if (
      error.code === "22023" ||
      error.code === "22P02" ||
      error.code === "23514"
    ) {
      throw new TaskOrderError("rejected");
    }
    throw new TaskOrderError("uncertain");
  }
  if (!isTaskOrderResult(data)) throw new TaskOrderError("uncertain");
  if (data.operation_id !== command.operation_id) {
    throw new TaskOrderError("uncertain");
  }
  return data;
}
