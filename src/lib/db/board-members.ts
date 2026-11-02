import type { SupabaseClient } from "@supabase/supabase-js";
import type { CurrentBoardMember } from "@/lib/types";

function isCurrentBoardMember(value: unknown): value is CurrentBoardMember {
  return (
    typeof value === "object" &&
    value !== null &&
    "membership_id" in value &&
    typeof value.membership_id === "string" &&
    "user_id" in value &&
    typeof value.user_id === "string" &&
    "name" in value &&
    typeof value.name === "string" &&
    value.name.length > 0 &&
    "role" in value &&
    (value.role === "owner" || value.role === "collaborator")
  );
}

/** List only the members of the board the authenticated caller can access. */
export async function listCurrentBoardMembers(
  supabase: SupabaseClient,
  slug: string,
): Promise<CurrentBoardMember[]> {
  const { data, error } = await supabase.rpc("list_board_members_p", {
    p_slug: slug,
  });
  if (error) throw error;
  if (!Array.isArray(data) || !data.every(isCurrentBoardMember)) {
    throw new Error("The current board member response is invalid.");
  }
  return data;
}
