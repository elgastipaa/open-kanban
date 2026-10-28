import type { SupabaseClient } from "@supabase/supabase-js";
import { useCallback, useRef } from "react";
import {
  createBoard,
  deleteBoard as dbDeleteBoard,
  getFullBoard,
} from "@/lib/db";
import type { Board, ColumnWithTasks } from "@/lib/types";
import type { TaskMutationLedger } from "./task-mutation-ledger";
import { getInitialLocalColumn, showMutationError } from "./utils";

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

  const refreshFromDB = useCallback(async () => {
    const generation = ++refreshGenerationRef.current;
    const data = await getFullBoard(supabase, slug);
    if (generation === refreshGenerationRef.current && data) {
      boardRef.current = data.board;
      isPersistedRef.current = true;
      setBoard(data.board);
      const nextColumns =
        data.columns.length > 0 ? data.columns : [getInitialLocalColumn()];
      setColumns(taskMutationLedger.sync(nextColumns));
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

  const persistBoard = useCallback(async (): Promise<Board> => {
    if (boardRef.current) return boardRef.current;

    const newBoard = await createBoard(supabase, slug);
    isPersistedRef.current = true;
    boardRef.current = newBoard;
    setBoard(newBoard);
    return newBoard;
  }, [slug, supabase, boardRef, isPersistedRef, setBoard]);

  const removeBoard = useCallback(async () => {
    if (boardRef.current && isPersistedRef.current) {
      try {
        await dbDeleteBoard(supabase, slug, boardRef.current.id);
      } catch {
        showMutationError("delete board");
        return;
      }
    }
    refreshGenerationRef.current += 1;
    boardRef.current = null;
    isPersistedRef.current = false;
    setBoard(null);
    setColumns(taskMutationLedger.sync([getInitialLocalColumn()], true));
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
      const nextColumns =
        newColumns.length > 0 ? newColumns : [getInitialLocalColumn()];
      setColumns(taskMutationLedger.sync(nextColumns, true));
    },
    [boardRef, isPersistedRef, setBoard, setColumns, taskMutationLedger],
  );

  return {
    refreshFromDB,
    persistBoard,
    removeBoard,
    replaceState,
  };
}
