import type { SupabaseClient } from "@supabase/supabase-js";
import type { ColumnDeletionCommand } from "@/lib/column-deletion-flow";
import type {
  Column,
  CreateColumnPayload,
  UpdateColumnPayload,
} from "@/lib/types";
import { createColumnSchema, updateColumnSchema } from "@/lib/validations";
import { handleSupabaseError } from "./errors";

/** Fetch all columns for a board, ordered by position */
export async function getColumns(
  supabase: SupabaseClient,
  boardId: string,
): Promise<Column[]> {
  const response = await supabase.rpc("get_columns_p", {
    p_board_id: boardId,
  });

  if (response.error) handleSupabaseError(response.error);
  return (response.data as Column[]) ?? [];
}

/** Create a new column (slug-scoped — Finding #7) */
export async function createColumn(
  supabase: SupabaseClient,
  slug: string,
  payload: CreateColumnPayload,
): Promise<Column> {
  createColumnSchema.parse(payload);

  const response = await supabase
    .rpc("create_column_p", {
      p_slug: slug,
      p_board_id: payload.board_id,
      p_title: payload.title,
      p_position: payload.position,
    })
    .single();

  if (response.error) handleSupabaseError(response.error);
  return response.data as Column;
}

/** Update a column (title, position, is_collapsed) */
export async function updateColumn(
  supabase: SupabaseClient,
  slug: string,
  payload: UpdateColumnPayload,
): Promise<Column> {
  updateColumnSchema.parse(payload);

  const { id, ...updates } = payload;
  const response = await supabase
    .rpc("update_column_p", {
      p_slug: slug,
      p_id: id,
      p_title: updates.title ?? null,
      p_position: updates.position ?? null,
      p_is_collapsed: updates.is_collapsed ?? null,
    })
    .single();

  if (response.error) handleSupabaseError(response.error);
  return response.data as Column;
}

/** Delete a column into recovery, moving its active tasks transactionally. */
export async function deleteColumn(
  supabase: SupabaseClient,
  slug: string,
  command: ColumnDeletionCommand,
): Promise<ColumnRecoveryResult> {
  if (!slug || !command.operation_id || !command.column_id) {
    throw new ColumnRecoveryError("rejected");
  }
  for (let attempt = 0; attempt < 2; attempt += 1) {
    let response: Awaited<ReturnType<SupabaseClient["rpc"]>>;
    try {
      response = await supabase.rpc("delete_column_p", {
        p_operation_id: command.operation_id,
        p_slug: slug,
        p_column_id: command.column_id,
        p_destination_column_id: command.destination_column_id,
        p_expected_task_order_version: command.expected_task_order_version,
      });
    } catch {
      if (attempt === 1) throw new ColumnRecoveryError("uncertain");
      continue;
    }
    if (response.error) {
      const definite = columnRecoveryErrorForCode(response.error.code ?? "");
      if (definite) throw definite;
      if (attempt === 1) throw new ColumnRecoveryError("uncertain");
      continue;
    }
    if (!isColumnRecoveryResult(response.data)) {
      throw new ColumnRecoveryError("uncertain");
    }
    if (response.data.operation_id !== command.operation_id) {
      throw new ColumnRecoveryError("uncertain");
    }
    return response.data;
  }
  throw new ColumnRecoveryError("uncertain");
}

export interface ColumnDeletionPreview {
  status: "preview";
  column_id: string;
  column_title: string;
  task_count: number;
  task_order_version: number;
  destinations: Array<{ id: string; title: string; position: number }>;
}

export type ColumnRecoveryResultStatus =
  | "confirmed"
  | "conflict"
  | "unavailable"
  | "needs_destination"
  | "expired"
  | "expired_unknown"
  | "retryable";

export interface ColumnRecoveryResult {
  status: ColumnRecoveryResultStatus;
  operation_id: string;
  column_id?: string;
  moved_task_count?: number;
  expires_at?: string;
}

export interface DeletedColumnRecoveryItem {
  column_id: string;
  title: string;
  original_position: number;
  destination_column_id: string | null;
  moved_task_count: number;
  deleted_by: string;
  deleted_at: string;
  expires_at: string;
  can_restore: boolean;
  eligibility_checked_at: string;
}

export type ColumnRecoveryErrorReason =
  | "access_denied"
  | "rejected"
  | "unavailable"
  | "uncertain";

export class ColumnRecoveryError extends Error {
  constructor(readonly reason: ColumnRecoveryErrorReason) {
    super(reason);
    this.name = "ColumnRecoveryError";
  }
}

function columnRecoveryErrorForCode(code: string): ColumnRecoveryError | null {
  if (code === "42501") return new ColumnRecoveryError("access_denied");
  if (code === "22023" || code === "22P02" || code === "23514") {
    return new ColumnRecoveryError("rejected");
  }
  return null;
}

function isColumnDeletionPreview(
  value: unknown,
): value is ColumnDeletionPreview {
  return (
    typeof value === "object" &&
    value !== null &&
    "status" in value &&
    value.status === "preview" &&
    "column_id" in value &&
    typeof value.column_id === "string" &&
    "column_title" in value &&
    typeof value.column_title === "string" &&
    "task_count" in value &&
    typeof value.task_count === "number" &&
    Number.isInteger(value.task_count) &&
    "task_order_version" in value &&
    typeof value.task_order_version === "number" &&
    Number.isInteger(value.task_order_version) &&
    "destinations" in value &&
    Array.isArray(value.destinations) &&
    value.destinations.every(
      (destination) =>
        typeof destination === "object" &&
        destination !== null &&
        "id" in destination &&
        typeof destination.id === "string" &&
        "title" in destination &&
        typeof destination.title === "string" &&
        "position" in destination &&
        typeof destination.position === "number" &&
        Number.isInteger(destination.position),
    )
  );
}

function isColumnRecoveryResult(value: unknown): value is ColumnRecoveryResult {
  return (
    typeof value === "object" &&
    value !== null &&
    "status" in value &&
    [
      "confirmed",
      "conflict",
      "unavailable",
      "needs_destination",
      "expired",
      "expired_unknown",
      "retryable",
    ].includes(String(value.status)) &&
    "operation_id" in value &&
    typeof value.operation_id === "string"
  );
}

function isDeletedColumnRecoveryItem(
  value: unknown,
): value is DeletedColumnRecoveryItem {
  return (
    typeof value === "object" &&
    value !== null &&
    "column_id" in value &&
    typeof value.column_id === "string" &&
    "title" in value &&
    typeof value.title === "string" &&
    "original_position" in value &&
    typeof value.original_position === "number" &&
    "moved_task_count" in value &&
    typeof value.moved_task_count === "number" &&
    "deleted_by" in value &&
    typeof value.deleted_by === "string" &&
    "deleted_at" in value &&
    typeof value.deleted_at === "string" &&
    "expires_at" in value &&
    typeof value.expires_at === "string" &&
    "can_restore" in value &&
    typeof value.can_restore === "boolean" &&
    "eligibility_checked_at" in value &&
    typeof value.eligibility_checked_at === "string"
  );
}

/** Load an authorized preview, including only destinations in this board. */
export async function previewDeleteColumn(
  supabase: SupabaseClient,
  slug: string,
  columnId: string,
): Promise<ColumnDeletionPreview> {
  const { data, error } = await supabase.rpc("preview_delete_column_p", {
    p_slug: slug,
    p_column_id: columnId,
  });
  if (error) {
    throw (
      columnRecoveryErrorForCode(error.code ?? "") ??
      new ColumnRecoveryError("uncertain")
    );
  }
  if (!isColumnDeletionPreview(data)) {
    throw new ColumnRecoveryError("unavailable");
  }
  return data;
}

/** Load only columns that the current board member can recover. */
export async function listDeletedColumns(
  supabase: SupabaseClient,
  slug: string,
): Promise<DeletedColumnRecoveryItem[]> {
  const { data, error } = await supabase.rpc("list_deleted_columns_p", {
    p_slug: slug,
  });
  if (error) {
    throw (
      columnRecoveryErrorForCode(error.code ?? "") ??
      new ColumnRecoveryError("uncertain")
    );
  }
  if (!Array.isArray(data) || !data.every(isDeletedColumnRecoveryItem)) {
    throw new ColumnRecoveryError("uncertain");
  }
  return data;
}

/** Restore only the column structure; the deletion never reverses task moves. */
export async function restoreColumn(
  supabase: SupabaseClient,
  slug: string,
  operationId: string,
  columnId: string,
): Promise<ColumnRecoveryResult> {
  if (!slug || !operationId || !columnId) {
    throw new ColumnRecoveryError("rejected");
  }
  for (let attempt = 0; attempt < 2; attempt += 1) {
    let response: Awaited<ReturnType<SupabaseClient["rpc"]>>;
    try {
      response = await supabase.rpc("restore_column_p", {
        p_operation_id: operationId,
        p_slug: slug,
        p_column_id: columnId,
      });
    } catch {
      if (attempt === 1) throw new ColumnRecoveryError("uncertain");
      continue;
    }
    if (response.error) {
      const definite = columnRecoveryErrorForCode(response.error.code ?? "");
      if (definite) throw definite;
      if (attempt === 1) throw new ColumnRecoveryError("uncertain");
      continue;
    }
    if (!isColumnRecoveryResult(response.data)) {
      throw new ColumnRecoveryError("uncertain");
    }
    if (response.data.operation_id !== operationId) {
      throw new ColumnRecoveryError("uncertain");
    }
    return response.data;
  }
  throw new ColumnRecoveryError("uncertain");
}

/** Maximum batch size for position updates (Finding #4) */
const MAX_BATCH_SIZE = 200;

/** Batch update column positions */
export async function updateColumnPositions(
  supabase: SupabaseClient,
  slug: string,
  updates: Column[],
): Promise<void> {
  if (updates.length === 0) return;

  const uniqueUpdates = Array.from(
    new Map(updates.map((item) => [item.id, item])).values(),
  );

  // Finding #4: Client-side batch size guard
  if (uniqueUpdates.length > MAX_BATCH_SIZE) {
    throw new Error(`Batch size exceeds maximum of ${MAX_BATCH_SIZE} items`);
  }

  const payload = uniqueUpdates.map((col) => ({
    id: col.id,
    position: col.position,
  }));

  const { error } = await supabase.rpc("update_column_positions_p", {
    p_slug: slug,
    p_updates: payload,
  });
  if (error) handleSupabaseError(error);
}

/** Batch toggle the collapse state of all columns for a board */
export async function batchToggleColumnsCollapse(
  supabase: SupabaseClient,
  slug: string,
  isCollapsed: boolean,
): Promise<void> {
  const { error } = await supabase.rpc("batch_toggle_columns_collapse_p", {
    p_slug: slug,
    p_is_collapsed: isCollapsed,
  });

  if (error) handleSupabaseError(error);
}
