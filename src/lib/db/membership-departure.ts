import type { SupabaseClient } from "@supabase/supabase-js";

export async function hasOtherCurrentBoardMembers(
  supabase: SupabaseClient,
  boardId: string,
): Promise<boolean> {
  const { data, error } = await supabase.rpc(
    "has_other_current_board_members_p",
    { p_board_id: boardId },
  );
  if (error) throw error;
  if (typeof data !== "boolean") {
    throw new Error("The board departure member count is invalid.");
  }
  return data;
}
