import type { SupabaseClient } from "@supabase/supabase-js";
import { isTaskEditReadAccessDeniedCode } from "@/lib/task-edit-read";
import type { Board, ColumnWithTasks } from "@/lib/types";
import { createBoardSchema } from "@/lib/validations";
import { handleSupabaseError } from "./errors";
import { TaskEditError } from "./tasks";

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
