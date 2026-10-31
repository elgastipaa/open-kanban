import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  BoardState,
  CreateTaskPayload,
  Task,
  TaskPositionUpdate,
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
): Promise<Task> {
  updateTaskSchema.parse(payload);

  const { id, ...updates } = payload;
  const response = await supabase
    .rpc("edit_task_fields_p", {
      p_slug: slug,
      p_id: id,
      p_updates: updates,
    })
    .single();

  if (response.error) handleSupabaseError(response.error);
  return response.data as Task;
}

/** Delete a task */
export async function deleteTask(
  supabase: SupabaseClient,
  slug: string,
  taskId: string,
): Promise<void> {
  const { error } = await supabase.rpc("delete_task_p", {
    p_slug: slug,
    p_id: taskId,
  });
  if (error) handleSupabaseError(error);
}

/** Maximum batch size for position updates (Finding #4) */
const MAX_BATCH_SIZE = 200;

/** Batch update only task positions and optional column assignments. */
export async function updateTaskPositions(
  supabase: SupabaseClient,
  slug: string,
  updates: TaskPositionUpdate[],
): Promise<Task[]> {
  if (updates.length === 0) return [];

  // Deduplicate by ID to prevent updating the same row twice in one batch
  const uniqueUpdates = Array.from(
    new Map(updates.map((item) => [item.id, item])).values(),
  );

  // Finding #4: Client-side batch size guard
  if (uniqueUpdates.length > MAX_BATCH_SIZE) {
    throw new Error(`Batch size exceeds maximum of ${MAX_BATCH_SIZE} items`);
  }

  const payload = uniqueUpdates.map((task) => ({
    id: task.id,
    ...(task.column_id !== undefined && { column_id: task.column_id }),
    position: task.position,
  }));

  const { data, error } = await supabase.rpc("update_task_positions_p", {
    p_slug: slug,
    p_updates: payload,
  });
  if (error) handleSupabaseError(error);
  return (data as Task[]) ?? [];
}
