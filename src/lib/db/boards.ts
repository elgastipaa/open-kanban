import type { SupabaseClient } from "@supabase/supabase-js";
import { isTaskEditReadAccessDeniedCode } from "@/lib/task-edit-read";
import type { Board, BoardTimeZonePreview, ColumnWithTasks } from "@/lib/types";
import { createBoardSchema } from "@/lib/validations";
import { handleSupabaseError } from "./errors";
import { TaskEditError } from "./tasks";

export type BoardTimeZoneErrorReason =
  | "invalid_time_zone"
  | "access_denied"
  | "conflict"
  | "uncertain";

export class BoardTimeZoneError extends Error {
  constructor(readonly reason: BoardTimeZoneErrorReason) {
    super(reason);
    this.name = "BoardTimeZoneError";
  }
}

function boardTimeZoneError(error: { code?: string }): BoardTimeZoneError {
  if (error.code === "42501") return new BoardTimeZoneError("access_denied");
  if (error.code === "22023") {
    return new BoardTimeZoneError("invalid_time_zone");
  }
  if (error.code === "23514") return new BoardTimeZoneError("conflict");
  return new BoardTimeZoneError("uncertain");
}

function isBoardTimeZonePreview(value: unknown): value is BoardTimeZonePreview {
  return (
    typeof value === "object" &&
    value !== null &&
    "time_zone" in value &&
    typeof value.time_zone === "string" &&
    "preview_time_zone" in value &&
    typeof value.preview_time_zone === "string" &&
    "today_before" in value &&
    typeof value.today_before === "string" &&
    "today_after" in value &&
    typeof value.today_after === "string" &&
    "due_today_before" in value &&
    typeof value.due_today_before === "number" &&
    "overdue_before" in value &&
    typeof value.overdue_before === "number" &&
    "due_today_after" in value &&
    typeof value.due_today_after === "number" &&
    "overdue_after" in value &&
    typeof value.overdue_after === "number" &&
    "due_dates_unchanged" in value &&
    value.due_dates_unchanged === true
  );
}

/** Preview date-state changes with the database clock and current board data. */
export async function previewBoardTimeZone(
  supabase: SupabaseClient,
  slug: string,
  timeZone: string,
): Promise<BoardTimeZonePreview> {
  const { data, error } = await supabase.rpc("preview_board_time_zone_p", {
    p_slug: slug,
    p_time_zone: timeZone,
  });
  if (error) throw boardTimeZoneError(error);
  if (!isBoardTimeZonePreview(data)) throw new BoardTimeZoneError("uncertain");
  return data;
}

/** Change only the owner's board zone after the preview is accepted. */
export async function updateBoardTimeZone(
  supabase: SupabaseClient,
  slug: string,
  expectedTimeZone: string,
  timeZone: string,
): Promise<Board> {
  const { data, error } = await supabase.rpc("update_board_time_zone_p", {
    p_slug: slug,
    p_expected_time_zone: expectedTimeZone,
    p_time_zone: timeZone,
  });
  if (error) throw boardTimeZoneError(error);
  if (
    typeof data !== "object" ||
    data === null ||
    !("time_zone" in data) ||
    typeof data.time_zone !== "string" ||
    !("today" in data) ||
    typeof data.today !== "string"
  ) {
    throw new BoardTimeZoneError("uncertain");
  }
  return data as Board;
}

/** Fetch a board by slug, returns null if not found */
export async function getBoard(
  supabase: SupabaseClient,
  slug: string,
): Promise<Board | null> {
  const response = await supabase
    .rpc("get_board_p", { p_slug: slug })
    .maybeSingle();

  if (response.error) handleSupabaseError(response.error);
  return response.data as Board | null;
}

/** Create an explicitly named board with a retry-safe operation id */
export async function createBoard(
  supabase: SupabaseClient,
  input: { name: string; time_zone: string; operation_id: string },
): Promise<Board> {
  const parsed = createBoardSchema.parse(input);

  const response = await supabase
    .rpc("create_board_p", {
      p_name: parsed.name,
      p_time_zone: parsed.time_zone,
      p_operation_id: parsed.operation_id,
    })
    .single();

  if (response.error) handleSupabaseError(response.error);
  return response.data as Board;
}

/** Delete a board and all its columns/tasks (cascade) */
export async function deleteBoard(
  supabase: SupabaseClient,
  slug: string,
  boardId: string,
): Promise<void> {
  const { error } = await supabase.rpc("delete_board_p", {
    p_slug: slug,
    p_id: boardId,
  });
  if (error) handleSupabaseError(error);
}

/** Fetch the complete board state: board + columns with nested tasks */
export async function getFullBoard(
  supabase: SupabaseClient,
  slug: string,
): Promise<{ board: Board; columns: ColumnWithTasks[] } | null> {
  const response = await supabase
    .rpc("get_full_board_p", { p_slug: slug })
    .maybeSingle();

  if (response.error) handleSupabaseError(response.error);
  return response.data as { board: Board; columns: ColumnWithTasks[] } | null;
}

/** Read a board for task-edit reconciliation without hiding SQL permission denial. */
export async function getFullBoardForTaskEdit(
  supabase: SupabaseClient,
  slug: string,
): Promise<{ board: Board; columns: ColumnWithTasks[] } | null> {
  const response = await supabase
    .rpc("get_full_board_p", { p_slug: slug })
    .maybeSingle();

  if (response.error) {
    if (isTaskEditReadAccessDeniedCode(response.error.code)) {
      throw new TaskEditError("access_denied");
    }
    handleSupabaseError(response.error);
  }
  return response.data as { board: Board; columns: ColumnWithTasks[] } | null;
}
