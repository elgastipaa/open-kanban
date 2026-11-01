import type { SupabaseClient } from "@supabase/supabase-js";
import { useCallback } from "react";
import type { ColumnDeletionCommand } from "@/lib/column-deletion-flow";
import {
  batchToggleColumnsCollapse,
  createColumn,
  deleteColumn as dbDeleteColumn,
  updateColumn,
  updateColumnPositions,
} from "@/lib/db";
import type { ColumnRecoveryResult } from "@/lib/db/columns";
import type { Board, Column, ColumnWithTasks } from "@/lib/types";
import type { TaskMutationLedger } from "./task-mutation-ledger";
import type { BoardRefreshOutcome } from "./use-board-sync";
import { makeLocalColumn, showMutationError } from "./utils";

interface UseColumnOperationsProps {
  slug: string;
  supabase: SupabaseClient;
  columnsRef: React.RefObject<ColumnWithTasks[]>;
  setColumns: React.Dispatch<React.SetStateAction<ColumnWithTasks[]>>;
  isPersistedRef: React.RefObject<boolean>;
  onMutationRef: React.RefObject<(() => void) | undefined>;
  persistBoard: () => Promise<Board>;
  refreshFromDB: () => Promise<BoardRefreshOutcome>;
  enqueue: (op: () => Promise<void>) => Promise<void>;
  ledger: TaskMutationLedger;
}

export function useColumnOperations({
  slug,
  supabase,
  columnsRef,
  setColumns,
  isPersistedRef,
  onMutationRef,
  persistBoard,
  refreshFromDB,
  enqueue,
  ledger,
}: UseColumnOperationsProps) {
  const addColumn = useCallback(
    (title: string) => {
      const trimmedTitle = title.trim();
      const position = columnsRef.current ? columnsRef.current.length : 0;
      const tempCol = makeLocalColumn(trimmedTitle, position);

      // Optimistic UI update
      setColumns((prev) => [...prev, tempCol]);

      // Queue DB operation
      enqueue(async () => {
        try {
          const board = await persistBoard();

          const dbCol = await createColumn(supabase, slug, {
            board_id: board.id,
            title: trimmedTitle,
            position,
          });

          setColumns((prev) =>
            ledger
              .replaceColumnId(tempCol.id, dbCol.id, prev)
              .map((col) =>
                col.id === dbCol.id
                  ? { ...dbCol, board_id: board.id, tasks: col.tasks }
                  : col,
              ),
          );
          onMutationRef.current?.();
        } catch {
          setColumns((prev) => prev.filter((col) => col.id !== tempCol.id));
          showMutationError("add column");
        }
      });
    },
    [
      columnsRef,
      setColumns,
      enqueue,
      persistBoard,
      supabase,
      slug,
      onMutationRef,
      ledger,
    ],
  );

  const renameColumn = useCallback(
    (columnId: string, title: string) => {
      const snapshot = columnsRef.current ?? [];

      // Optimistic UI update
      setColumns((prev) =>
        prev.map((col) => (col.id === columnId ? { ...col, title } : col)),
      );

      if (!isPersistedRef.current || columnId.startsWith("local-")) return;

      enqueue(async () => {
        try {
          await updateColumn(supabase, slug, { id: columnId, title });
          onMutationRef.current?.();
        } catch {
          setColumns(snapshot);
          showMutationError("rename column");
        }
      });
    },
    [
      columnsRef,
      setColumns,
      isPersistedRef,
      enqueue,
      supabase,
      slug,
      onMutationRef,
    ],
  );

  const toggleColumnCollapse = useCallback(
    (columnId: string, is_collapsed: boolean) => {
      const snapshot = columnsRef.current ?? [];

      // Optimistic UI update
      setColumns((prev) =>
        prev.map((col) =>
          col.id === columnId ? { ...col, is_collapsed } : col,
        ),
      );

      if (!isPersistedRef.current || columnId.startsWith("local-")) return;

      enqueue(async () => {
        try {
          await updateColumn(supabase, slug, { id: columnId, is_collapsed });
          onMutationRef.current?.();
        } catch {
          setColumns(snapshot);
          showMutationError("toggle column");
        }
      });
    },
    [
      columnsRef,
      setColumns,
      isPersistedRef,
      enqueue,
      supabase,
      slug,
      onMutationRef,
    ],
  );

  const toggleAllColumnsCollapse = useCallback(
    (is_collapsed: boolean) => {
      const currentCols = columnsRef.current ?? [];

      // Check if all columns are already in the desired state
      const isAlreadyInState = currentCols.every(
        (col) => col.is_collapsed === is_collapsed,
      );
      if (isAlreadyInState) return;

      const snapshot = currentCols;

      // Optimistic UI update
      setColumns((prev) => prev.map((col) => ({ ...col, is_collapsed })));

      if (!isPersistedRef.current) return;

      enqueue(async () => {
        try {
          await batchToggleColumnsCollapse(supabase, slug, is_collapsed);
          onMutationRef.current?.();
        } catch {
          setColumns(snapshot);
          showMutationError(
            `toggle all columns ${is_collapsed ? "collapse" : "expand"}`,
          );
        }
      });
    },
    [
      columnsRef,
      setColumns,
      isPersistedRef,
      enqueue,
      supabase,
      slug,
      onMutationRef,
    ],
  );

  const removeColumn = useCallback(
    async (command: ColumnDeletionCommand): Promise<ColumnRecoveryResult> => {
      if (!isPersistedRef.current || command.column_id.startsWith("local-")) {
        throw new Error("No se puede recuperar una columna sin guardar.");
      }
      let result: ColumnRecoveryResult | null = null;
      let failure: unknown;
      await enqueue(async () => {
        try {
          result = await dbDeleteColumn(supabase, slug, command);
          await refreshFromDB();
          if (result.status === "confirmed") onMutationRef.current?.();
        } catch (error) {
          failure = error;
          try {
            await refreshFromDB();
          } catch {
            // Preserve the original operation error; the UI will ask for review.
          }
        }
      });
      if (failure) throw failure;
      if (!result)
        throw new Error("No se recibió el resultado de la operación.");
      return result;
    },
    [isPersistedRef, enqueue, supabase, slug, onMutationRef, refreshFromDB],
  );

  const moveColumn = useCallback(
    (sourceIndex: number, destIndex: number) => {
      const currentCols = columnsRef.current ?? [];
      const snapshot = currentCols;

      const newCols = [...currentCols];
      const [moved] = newCols.splice(sourceIndex, 1);
      if (!moved) return;
      newCols.splice(destIndex, 0, moved);
      const result = newCols.map((col, i) => ({ ...col, position: i }));

      // Optimistic UI update
      setColumns(result);

      if (!isPersistedRef.current) return;

      const colUpdates: Column[] = result.map((col) => ({
        id: col.id,
        board_id: col.board_id,
        title: col.title,
        position: col.position,
        is_collapsed: col.is_collapsed,
        task_order_version: col.task_order_version,
        created_at: col.created_at,
      }));

      enqueue(async () => {
        try {
          await updateColumnPositions(supabase, slug, colUpdates);
          onMutationRef.current?.();
        } catch {
          setColumns(snapshot);
          showMutationError("move column");
        }
      });
    },
    [
      columnsRef,
      setColumns,
      isPersistedRef,
      enqueue,
      supabase,
      slug,
      onMutationRef,
    ],
  );

  return {
    addColumn,
    renameColumn,
    toggleColumnCollapse,
    toggleAllColumnsCollapse,
    removeColumn,
    moveColumn,
  };
}
