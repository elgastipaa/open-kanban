"use client";

import { useCallback, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Board, ColumnWithTasks } from "@/lib/types";
import { TaskMutationLedger } from "./use-board/task-mutation-ledger";
import type { UseBoardOptions } from "./use-board/types";
import { useBoardSync } from "./use-board/use-board-sync";
import { useColumnOperations } from "./use-board/use-column-operations";
import { useTaskOperations } from "./use-board/use-task-operations";

export function useBoard({
  actorId,
  slug,
  initialBoard,
  initialColumns,
  authEpoch,
  onMutation,
  onAccessLost,
}: UseBoardOptions) {
  const [board, setBoard] = useState<Board | null>(initialBoard);
  const [columns, setColumns] = useState<ColumnWithTasks[]>(initialColumns);
  const taskMutationLedgerRef = useRef<TaskMutationLedger | null>(null);
  if (!taskMutationLedgerRef.current) {
    taskMutationLedgerRef.current = new TaskMutationLedger(columns);
  }
  const taskMutationLedger = taskMutationLedgerRef.current;

  /** Whether board + columns have been persisted to DB */
  const isPersistedRef = useRef(initialBoard !== null);
  /** Store the board object for use across async calls */
  const boardRef = useRef<Board | null>(initialBoard);
  /** Store the latest columns for use in async queued closures */
  const columnsRef = useRef(columns);
  columnsRef.current = columns;
  /** Ref to latest onMutation callback (avoids stale closures) */
  const onMutationRef = useRef(onMutation);
  onMutationRef.current = onMutation;

  /** Async mutation queue: ensures one DB operation runs at a time */
  const queueRef = useRef<Promise<void>>(Promise.resolve());

  const enqueue = useCallback((operation: () => Promise<void>) => {
    const queued = queueRef.current.then(operation).catch((err) => {
      console.error("Mutation queue error:", err);
    });
    queueRef.current = queued;
    return queued;
  }, []);

  const supabase = createClient();

  const {
    refreshFromDB,
    persistBoard,
    applyBoardSettings,
    removeBoard,
    replaceState,
  } = useBoardSync({
    slug,
    supabase,
    authEpoch,
    onAccessLost,
    boardRef,
    isPersistedRef,
    setBoard,
    setColumns,
    taskMutationLedger,
  });

  const {
    addColumn,
    renameColumn,
    toggleColumnCollapse,
    toggleAllColumnsCollapse,
    removeColumn,
    moveColumn,
  } = useColumnOperations({
    slug,
    supabase,
    columnsRef,
    setColumns,
    isPersistedRef,
    onMutationRef,
    persistBoard,
    refreshFromDB,
    enqueue,
    ledger: taskMutationLedger,
  });

  const {
    addTask,
    editTask,
    completeTask,
    mutateChecklistStep,
    checklistAddOperations,
    refreshTaskForEdit,
    removeTask,
    moveTask,
  } = useTaskOperations({
    actorId,
    slug,
    supabase,
    columnsRef,
    setColumns,
    isPersistedRef,
    onMutationRef,
    persistBoard,
    enqueue,
    ledger: taskMutationLedger,
    onAccessLost: onAccessLost ?? (() => undefined),
  });

  return {
    board,
    columns,
    addColumn,
    renameColumn,
    toggleColumnCollapse,
    toggleAllColumnsCollapse,
    removeColumn,
    addTask,
    editTask,
    completeTask,
    mutateChecklistStep,
    checklistAddOperations,
    refreshTaskForEdit,
    removeTask,
    moveTask,
    moveColumn,
    removeBoard,
    replaceState,
    refreshFromDB,
    applyBoardSettings,
  };
}
