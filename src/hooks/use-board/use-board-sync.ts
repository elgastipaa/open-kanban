import type { SupabaseClient } from "@supabase/supabase-js";
import { useCallback, useRef } from "react";
import { isBoardSnapshotForCurrentSession } from "@/lib/board-auth-epoch";
import {
  type BoardRecoveryResult,
  deleteBoard as dbDeleteBoard,
  getFullBoard,
} from "@/lib/db";
import { BoardSnapshotReadError } from "@/lib/db/boards";
import { getSessionEpoch } from "@/lib/supabase/client";
import type { Board, ColumnWithTasks } from "@/lib/types";
import type { TaskMutationLedger } from "./task-mutation-ledger";

interface UseBoardSyncProps {
  slug: string;
  supabase: SupabaseClient;
  authEpoch: string | number;
  onAccessLost?: () => void;
  boardRef: React.RefObject<Board | null>;
  isPersistedRef: React.RefObject<boolean>;
  setBoard: React.Dispatch<React.SetStateAction<Board | null>>;
  setColumns: React.Dispatch<React.SetStateAction<ColumnWithTasks[]>>;
  taskMutationLedger: TaskMutationLedger;
}

export type BoardRefreshOutcome =
  | { status: "authorized"; authEpoch: string | number; taskIds: string[] }
  | { status: "denied" | "retryable" | "unavailable" | "discarded" };

export function useBoardSync({
  slug,
  supabase,
  authEpoch,
  onAccessLost,
  boardRef,
  isPersistedRef,
  setBoard,
  setColumns,
  taskMutationLedger,
}: UseBoardSyncProps) {
  const refreshGenerationRef = useRef(0);
  const authorizationEpochRef = useRef(authEpoch);
  authorizationEpochRef.current = authEpoch;

  const refreshFromDB = useCallback(async (): Promise<BoardRefreshOutcome> => {
    const generation = ++refreshGenerationRef.current;
    const ledgerRevision = taskMutationLedger.revision;
    const sessionEpoch = getSessionEpoch();
    const authorizationEpoch = authorizationEpochRef.current;
    let data: Awaited<ReturnType<typeof getFullBoard>>;
    try {
      data = await getFullBoard(supabase, slug);
    } catch (error) {
      if (
        sessionEpoch !== getSessionEpoch() ||
        String(authorizationEpoch) !==
          String(authorizationEpochRef.current) ||
        generation !== refreshGenerationRef.current ||
        ledgerRevision !== taskMutationLedger.revision
      ) {
        return { status: "discarded" };
      }
      if (error instanceof BoardSnapshotReadError) {
        if (error.reason === "unavailable") return { status: "unavailable" };
        if (error.reason === "retryable") return { status: "retryable" };
        boardRef.current = null;
        isPersistedRef.current = false;
        setBoard(null);
        setColumns(taskMutationLedger.sync([], true));
        onAccessLost?.();
        return { status: "denied" };
      }
      throw error;
    }
    if (
      isBoardSnapshotForCurrentSession(
        sessionEpoch,
        getSessionEpoch(),
        authorizationEpoch,
        authorizationEpochRef.current,
        data?.board.auth_epoch,
      ) &&
      generation === refreshGenerationRef.current &&
      ledgerRevision === taskMutationLedger.revision &&
      data
    ) {
      boardRef.current = data.board;
      isPersistedRef.current = true;
      setBoard(data.board);
      setColumns(taskMutationLedger.sync(data.columns));
      return {
        status: "authorized",
        authEpoch: data.board.auth_epoch ?? authorizationEpoch,
        taskIds: data.columns.flatMap((column) =>
          column.tasks.map((task) => task.id),
        ),
      };
    } else if (
      data === null &&
      sessionEpoch === getSessionEpoch() &&
      String(authorizationEpoch) === String(authorizationEpochRef.current) &&
      generation === refreshGenerationRef.current
    ) {
      boardRef.current = null;
      isPersistedRef.current = false;
      setBoard(null);
      setColumns(taskMutationLedger.sync([], true));
      onAccessLost?.();
      return { status: "denied" };
    }
    return { status: "discarded" };
  }, [
    slug,
    supabase,
    boardRef,
    isPersistedRef,
    setBoard,
    setColumns,
    taskMutationLedger,
    onAccessLost,
  ]);

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

  const removeBoard = useCallback(
    async (operationId: string) => {
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
    },
    [
      supabase,
      slug,
      boardRef,
      isPersistedRef,
      setBoard,
      setColumns,
      taskMutationLedger,
    ],
  );

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
    persistBoard,
    applyBoardSettings,
    removeBoard,
    replaceState,
  };
}
