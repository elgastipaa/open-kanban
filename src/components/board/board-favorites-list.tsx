"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import {
  boardFavoriteFailureMessage,
  groupFavoriteBoards,
  updateFavoriteIds,
  updatePendingFavoriteIds,
} from "@/lib/board-favorites-state";
import { setBoardFavorite } from "@/lib/db/board-favorites";
import { createClient } from "@/lib/supabase/client";
import type { Board } from "@/lib/types";

interface BoardFavoritesListProps {
  boards: Board[];
  favoriteBoardIds: string[];
  boardsLoadError: boolean;
  favoritesLoadError: boolean;
}

export function BoardFavoritesList({
  boards,
  favoriteBoardIds,
  boardsLoadError,
  favoritesLoadError,
}: BoardFavoritesListProps) {
  const router = useRouter();
  const pendingBoardIdsRef = useRef(new Set<string>());
  const [favoriteIds, setFavoriteIds] = useState<Set<string>>(
    () => new Set(favoriteBoardIds),
  );
  const [pendingBoardIds, setPendingBoardIds] = useState<Set<string>>(
    () => new Set(),
  );
  const [mutationError, setMutationError] = useState<string | null>(null);

  useEffect(() => {
    setFavoriteIds(new Set(favoriteBoardIds));
  }, [favoriteBoardIds]);

  async function toggleFavorite(boardId: string) {
    if (pendingBoardIdsRef.current.has(boardId) || favoritesLoadError) return;

    const nextValue = !favoriteIds.has(boardId);
    const pending = updatePendingFavoriteIds(
      pendingBoardIdsRef.current,
      boardId,
      true,
    );
    pendingBoardIdsRef.current = pending;
    setPendingBoardIds(pending);
    setMutationError(null);

    try {
      await setBoardFavorite(createClient(), boardId, nextValue);
      setFavoriteIds((current) =>
        updateFavoriteIds(current, boardId, nextValue),
      );
    } catch (error) {
      setMutationError(boardFavoriteFailureMessage(error));
      router.refresh();
    } finally {
      const remaining = updatePendingFavoriteIds(
        pendingBoardIdsRef.current,
        boardId,
        false,
      );
      pendingBoardIdsRef.current = remaining;
      setPendingBoardIds(remaining);
    }
  }

  if (boardsLoadError) {
    return (
      <section
        aria-label="Tus tableros"
        className="mt-8 rounded-xl border border-red-400/20 bg-red-400/5 p-4 text-red-200 text-sm"
        role="alert"
      >
        <p>No se pudieron cargar tus tableros.</p>
        <button
          className="mt-3 rounded-lg border border-red-200/30 px-3 py-2 text-red-100 transition hover:bg-red-200/10"
          onClick={() => router.refresh()}
          type="button"
        >
          Reintentar
        </button>
      </section>
    );
  }

  if (boards.length === 0) {
    return (
      <p className="mt-8 rounded-2xl border border-white/15 border-dashed p-10 text-center text-neutral-400 text-sm">
        Todavía no tienes tableros. Acepta una invitación o crea uno para
        empezar.
      </p>
    );
  }

  const { favorites, others } = groupFavoriteBoards(
    boards,
    favoritesLoadError ? new Set<string>() : favoriteIds,
  );
  const otherBoards = favoritesLoadError ? boards : others;

  function boardCard(board: Board, isFavorite: boolean) {
    const isPending = pendingBoardIds.has(board.id);
    return (
      <li key={board.id}>
        <div className="flex min-h-24 items-center gap-3 rounded-2xl border border-white/10 bg-neutral-950 p-5 transition hover:border-white/25 hover:bg-neutral-900">
          <Link className="min-w-0 flex-1" href={`/${board.slug}`}>
            <span className="block truncate font-semibold">{board.name}</span>
            <span className="mt-2 block text-neutral-500 text-xs">
              {board.role === "owner" ? "Propietario" : "Compartido contigo"}
            </span>
          </Link>
          {favoritesLoadError ? null : (
            <button
              aria-busy={isPending}
              aria-disabled={isPending}
              aria-label={
                isFavorite
                  ? `Quitar ${board.name} de favoritos`
                  : `Marcar ${board.name} como favorito`
              }
              aria-pressed={isFavorite}
              className="grid size-11 shrink-0 place-items-center rounded-full text-2xl text-amber-300 transition hover:bg-white/10 focus-visible:outline-2 focus-visible:outline-amber-300 focus-visible:outline-offset-2 aria-disabled:cursor-wait aria-disabled:opacity-60"
              onClick={() => void toggleFavorite(board.id)}
              type="button"
            >
              <span aria-hidden="true">{isFavorite ? "★" : "☆"}</span>
            </button>
          )}
        </div>
      </li>
    );
  }

  return (
    <div className="mt-8 space-y-8">
      <section aria-labelledby="favorites-heading">
        <h2
          className="font-display font-semibold text-xl"
          id="favorites-heading"
        >
          Favoritos
        </h2>
        {favoritesLoadError ? (
          <div
            className="mt-3 rounded-xl border border-red-400/20 bg-red-400/5 p-4 text-red-200 text-sm"
            role="alert"
          >
            <p>No se pudieron consultar tus favoritos.</p>
            <button
              className="mt-3 rounded-lg border border-red-200/30 px-3 py-2 text-red-100 transition hover:bg-red-200/10"
              onClick={() => router.refresh()}
              type="button"
            >
              Reintentar
            </button>
          </div>
        ) : favorites.length === 0 ? (
          <p className="mt-3 text-neutral-500 text-sm">
            Marca un tablero con la estrella para encontrarlo aquí.
          </p>
        ) : (
          <ul className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {favorites.map((board) => boardCard(board, true))}
          </ul>
        )}
      </section>

      {mutationError ? (
        <p
          className="rounded-xl border border-red-400/20 bg-red-400/5 p-4 text-red-200 text-sm"
          role="alert"
        >
          {mutationError}
        </p>
      ) : null}

      <section aria-labelledby="other-boards-heading">
        <h2
          className="font-display font-semibold text-xl"
          id="other-boards-heading"
        >
          {favoritesLoadError ? "Tus tableros" : "Otros tableros"}
        </h2>
        {otherBoards.length === 0 ? (
          <p className="mt-3 text-neutral-500 text-sm">
            Todos tus tableros están en Favoritos.
          </p>
        ) : (
          <ul className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {otherBoards.map((board) => boardCard(board, false))}
          </ul>
        )}
      </section>
    </div>
  );
}
