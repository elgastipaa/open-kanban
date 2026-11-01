import type { SupabaseClient } from "@supabase/supabase-js";
import { useCallback, useRef } from "react";
import {
  deleteBoard as dbDeleteBoard,
  getBoard,
  getFullBoard,
  type BoardRecoveryResult,
} from "@/lib/db";
import { getSessionEpoch } from "@/lib/supabase/client";
import type { Board, ColumnWithTasks } from "@/lib/types";
import type { TaskMutationLedger } from "./task-mutation-ledger";

interface UseBoardSyncProps {
  slug: string;
  supabase: SupabaseClient;
  boardRef: React.RefObject<Board | null>;
  isPersistedRef: React.RefObject<boolean>;
  setBoard: React.Dispatch<React.SetStateAction<Board | null>>;
  setColumns: React.Dispatch<React.SetStateAction<ColumnWithTasks[]>>;
  taskMutationLedger: TaskMutationLedger;
}

export function useBoardSync({
  slug,
  supabase,
  boardRef,
  isPersistedRef,
  setBoard,
  setColumns,
  taskMutationLedger,
}: UseBoardSyncProps) {
  const refreshGenerationRef = useRef(0);
  const boardRefreshGenerationRef = useRef(0);

  const refreshFromDB = useCallback(async () => {
    boardRefreshGenerationRef.current += 1;
    const generation = ++refreshGenerationRef.current;
    const ledgerRevision = taskMutationLedger.revision;
    const sessionEpoch = getSessionEpoch();
    let data: Awaited<ReturnType<typeof getFullBoard>>;
    try {
      data = await getFullBoard(supabase, slug);
    } catch (error) {
      if (sessionEpoch !== getSessionEpoch()) return;
      throw error;
    }
    if (
      sessionEpoch === getSessionEpoch() &&
      generation === refreshGenerationRef.current &&
      ledgerRevision === taskMutationLedger.revision &&
      data
    ) {
      boardRef.current = data.board;
      isPersistedRef.current = true;
      setBoard(data.board);
      setColumns(taskMutationLedger.sync(data.columns));
    }
  }, [
    slug,
    supabase,
    boardRef,
    isPersistedRef,
    setBoard,
    setColumns,
    taskMutationLedger,
  ]);

  const refreshBoardFromDB = useCallback(async () => {
    const generation = ++boardRefreshGenerationRef.current;
    const sessionEpoch = getSessionEpoch();
    const latestBoard = await getBoard(supabase, slug);
    if (
      sessionEpoch === getSessionEpoch() &&
      generation === boardRefreshGenerationRef.current &&
      latestBoard
    ) {
      boardRef.current = latestBoard;
      isPersistedRef.current = true;
      setBoard(latestBoard);
    }
  }, [slug, supabase, boardRef, isPersistedRef, setBoard]);

  const persistBoard = useCallback(async (): Promise<Board> => {
    if (boardRef.current) return boardRef.current;
    throw new Error("This board is no longer available.");
  }, [boardRef]);

  const applyBoardSettings = useCallback(
    (nextBoard: Board) => {
      boardRef.current = nextBoard;
      isPersistedRef.current = true;
      setBoard(nextBoard);
    },
    [boardRef, isPersistedRef, setBoard],
  );

  const removeBoard = useCallback(async (operationId: string) => {
    if (!boardRef.current || !isPersistedRef.current) return null;
    const result: BoardRecoveryResult = await dbDeleteBoard(
      supabase,
      slug,
      boardRef.current.id,
      operationId,
    );
    if (result.status !== "recoverable") return null;
    refreshGenerationRef.current += 1;
    boardRef.current = null;
    isPersistedRef.current = false;
    setBoard(null);
    setColumns(taskMutationLedger.sync([], true));
    return result;
  }, [
    supabase,
    slug,
    boardRef,
    isPersistedRef,
    setBoard,
    setColumns,
    taskMutationLedger,
  ]);

  const replaceState = useCallback(
    (newBoard: Board | null, newColumns: ColumnWithTasks[]) => {
      refreshGenerationRef.current += 1;
      boardRef.current = newBoard;
      isPersistedRef.current = newBoard !== null;
      setBoard(newBoard);
      setColumns(taskMutationLedger.sync(newColumns, true));
    },
    [boardRef, isPersistedRef, setBoard, setColumns, taskMutationLedger],
  );

  return {
    refreshFromDB,
    refreshBoardFromDB,
    persistBoard,
    applyBoardSettings,
    removeBoard,
    replaceState,
  };
}
