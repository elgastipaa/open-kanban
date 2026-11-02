import type { SupabaseClient } from "@supabase/supabase-js";

export class BoardFavoriteError extends Error {
  readonly reason: "access_denied" | "uncertain";

  constructor(reason: "access_denied" | "uncertain") {
    super("No se pudo confirmar el cambio de favorito.");
    this.name = "BoardFavoriteError";
    this.reason = reason;
  }
}

function boardFavoriteError(error: { code?: string }): BoardFavoriteError {
  if (error.code === "42501") return new BoardFavoriteError("access_denied");
  return new BoardFavoriteError("uncertain");
}

function isFavoriteRow(value: unknown): value is { board_id: string } {
  return (
    typeof value === "object" &&
    value !== null &&
    "board_id" in value &&
    typeof value.board_id === "string"
  );
}

/** Read only this user's favorites that still have current board membership. */
export async function listMyBoardFavoriteIds(
  supabase: SupabaseClient,
): Promise<string[]> {
  const { data, error } = await supabase.rpc("list_my_board_favorites_p");
  if (error) throw boardFavoriteError(error);
  if (!Array.isArray(data) || !data.every(isFavoriteRow)) {
    throw new BoardFavoriteError("uncertain");
  }
  return data.map((favorite) => favorite.board_id);
}

/** Persist a desired state so retries cannot invert a previously committed change. */
export async function setBoardFavorite(
  supabase: SupabaseClient,
  boardId: string,
  isFavorite: boolean,
): Promise<void> {
  const { data, error } = await supabase.rpc("set_board_favorite_p", {
    p_board_id: boardId,
    p_is_favorite: isFavorite,
  });
  if (error) throw boardFavoriteError(error);
  if (data !== isFavorite) throw new BoardFavoriteError("uncertain");
}
