export function groupFavoriteBoards<T extends { id: string }>(
  boards: readonly T[],
  favoriteIds: ReadonlySet<string>,
): { favorites: T[]; others: T[] } {
  return {
    favorites: boards.filter((board) => favoriteIds.has(board.id)),
    others: boards.filter((board) => !favoriteIds.has(board.id)),
  };
}

export function updateFavoriteIds(
  current: ReadonlySet<string>,
  boardId: string,
  isFavorite: boolean,
): Set<string> {
  const updated = new Set(current);
  if (isFavorite) updated.add(boardId);
  else updated.delete(boardId);
  return updated;
}

export function updatePendingFavoriteIds(
  current: ReadonlySet<string>,
  boardId: string,
  isPending: boolean,
): Set<string> {
  const updated = new Set(current);
  if (isPending) updated.add(boardId);
  else updated.delete(boardId);
  return updated;
}

export function focusFavoriteBoardButton(
  buttons: ReadonlyMap<string, { focus: () => void }>,
  boardId: string,
): boolean {
  const button = buttons.get(boardId);
  if (!button) return false;
  button.focus();
  return true;
}

export function boardFavoriteFailureMessage(error: unknown): string {
  if (
    error instanceof Error &&
    error.name === "BoardFavoriteError" &&
    "reason" in error &&
    error.reason === "access_denied"
  ) {
    return "No se pudo confirmar el acceso. Actualiza la lista para continuar.";
  }
  return "No se pudo guardar el favorito. Inténtalo de nuevo.";
}
