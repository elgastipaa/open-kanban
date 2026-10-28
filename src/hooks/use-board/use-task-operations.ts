import type { SupabaseClient } from "@supabase/supabase-js";
import { useCallback, useRef } from "react";
import {
  createColumn,
  createTask,
  deleteTask as dbDeleteTask,
  updateTask,
  updateTaskPositions,
} from "@/lib/db";
import type {
  Board,
  ColumnWithTasks,
  CreateTaskPayload,
  Priority,
  Task,
  TaskPositionUpdate,
} from "@/lib/types";
import { generateUUID } from "@/lib/utils";
import type {
  TaskMutationIntent,
  TaskMutationLedger,
  TaskMutationResult,
} from "./task-mutation-ledger";
import { showMutationError } from "./utils";

interface UseTaskOperationsProps {
  slug: string;
  supabase: SupabaseClient;
  columnsRef: React.RefObject<ColumnWithTasks[]>;
  setColumns: React.Dispatch<React.SetStateAction<ColumnWithTasks[]>>;
  isPersistedRef: React.RefObject<boolean>;
  onMutationRef: React.RefObject<(() => void) | undefined>;
  persistBoard: () => Promise<Board>;
  enqueue: (op: () => Promise<void>) => void;
  ledger: TaskMutationLedger;
}

export function useTaskOperations({
  slug,
  supabase,
  columnsRef,
  setColumns,
  isPersistedRef,
  onMutationRef,
  persistBoard,
  enqueue,
  ledger,
}: UseTaskOperationsProps) {
  const localColumnIds = useRef(new Map<string, string>());

  const addTask = useCallback(
    (columnId: string, title: string, priority: Priority = "medium") => {
      const currentCols = columnsRef.current ?? [];
      const col = currentCols.find((c) => c.id === columnId);
      const position = col ? col.tasks.length : 0;

      // Optimistic: add a temp task immediately
      const tempTask: Task = {
        id: `local-${generateUUID()}`,
        column_id: columnId,
        title,
        description: null,
        priority,
        position,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };

      setColumns((prev) =>
        prev.map((c) =>
          c.id === columnId ? { ...c, tasks: [...c.tasks, tempTask] } : c,
        ),
      );

      enqueue(async () => {
        try {
          // Ensure board exists
          const board = await persistBoard();
          let targetColumnId = localColumnIds.current.get(columnId) ?? columnId;

          // If the target column is still unpersisted local-, create it first
          if (targetColumnId.startsWith("local-")) {
            const currentSnapshot = columnsRef.current ?? [];
            const targetCol = currentSnapshot.find(
              (column) => column.id === targetColumnId,
            );
            if (targetCol) {
              const newCol = await createColumn(supabase, slug, {
                board_id: board.id,
                title: targetCol.title,
                position: targetCol.position,
              });
              const oldColumnId = targetColumnId;
              localColumnIds.current.set(columnId, newCol.id);
              localColumnIds.current.set(oldColumnId, newCol.id);
              targetColumnId = newCol.id;
              const withSavedColumn = (columnsRef.current ?? []).map(
                (column) =>
                  column.id === oldColumnId
                    ? { ...column, id: newCol.id }
                    : column,
              );
              setColumns(
                ledger.replaceColumnId(oldColumnId, newCol.id, withSavedColumn),
              );
            }
          }

          const payload: CreateTaskPayload = {
            column_id: targetColumnId,
            title,
            priority,
            position,
          };
          const dbTask = await createTask(supabase, slug, payload);

          const current = columnsRef.current ?? [];
          const taskStillExists = current.some((column) =>
            column.tasks.some((task) => task.id === tempTask.id),
          );
          if (!taskStillExists) {
            try {
              await dbDeleteTask(supabase, slug, dbTask.id);
            } catch {
              setColumns(ledger.replaceTaskId(tempTask.id, dbTask, current));
              showMutationError("delete task");
              return;
            }
            setColumns(ledger.forgetTask(tempTask.id, current));
            onMutationRef.current?.();
            return;
          }

          const withSavedTask = current.map((column) => ({
            ...column,
            tasks: column.tasks.map((task) =>
              task.id === tempTask.id ? dbTask : task,
            ),
          }));
          setColumns(ledger.replaceTaskId(tempTask.id, dbTask, withSavedTask));
          onMutationRef.current?.();
        } catch {
          // Rollback task addition
          const current = columnsRef.current ?? [];
          setColumns(
            ledger.forgetTask(
              tempTask.id,
              current.map((column) => ({
                ...column,
                tasks: column.tasks.filter((task) => task.id !== tempTask.id),
              })),
            ),
          );
          showMutationError("add task");
        }
      });
    },
    [
      columnsRef,
      setColumns,
      ledger,
      enqueue,
      persistBoard,
      supabase,
      slug,
      onMutationRef,
    ],
  );

  const editTask = useCallback(
    (
      taskId: string,
      updates: {
        title?: string;
        description?: string | null;
        priority?: Priority;
      },
    ) => {
      const intent: TaskMutationIntent = {
        id: generateUUID(),
        kind: "edit",
        taskId,
        updates,
      };
      const optimisticColumns = ledger.begin(intent, columnsRef.current ?? []);
      setColumns(optimisticColumns);

      if (!isPersistedRef.current || taskId.startsWith("local-")) {
        const task = optimisticColumns
          .flatMap((column) => column.tasks)
          .find((candidate) => candidate.id === taskId);
        const saved: TaskMutationResult | undefined = task
          ? { kind: "task-saved", task: { ...task, ...updates } }
          : undefined;
        setColumns(ledger.settle(intent.id, optimisticColumns, saved));
        return;
      }

      enqueue(async () => {
        try {
          const savedTask = await updateTask(supabase, slug, {
            id: taskId,
            ...updates,
          });
          setColumns(
            ledger.settle(intent.id, columnsRef.current ?? [], {
              kind: "task-saved",
              task: savedTask,
            }),
          );
          onMutationRef.current?.();
        } catch {
          setColumns(ledger.settle(intent.id, columnsRef.current ?? []));
          showMutationError("update task");
        }
      });
    },
    [
      supabase,
      slug,
      columnsRef,
      setColumns,
      isPersistedRef,
      ledger,
      enqueue,
      onMutationRef,
    ],
  );

  const removeTask = useCallback(
    (taskId: string) => {
      const intent: TaskMutationIntent = {
        id: generateUUID(),
        kind: "delete",
        taskId,
      };
      const optimisticColumns = ledger.begin(intent, columnsRef.current ?? []);
      setColumns(optimisticColumns);

      if (!isPersistedRef.current || taskId.startsWith("local-")) {
        setColumns(
          ledger.settle(intent.id, optimisticColumns, { kind: "task-deleted" }),
        );
        return;
      }

      enqueue(async () => {
        try {
          await dbDeleteTask(supabase, slug, taskId);
          setColumns(
            ledger.settle(intent.id, columnsRef.current ?? [], {
              kind: "task-deleted",
            }),
          );
          onMutationRef.current?.();
        } catch {
          setColumns(ledger.settle(intent.id, columnsRef.current ?? []));
          showMutationError("delete task");
        }
      });
    },
    [
      supabase,
      slug,
      columnsRef,
      setColumns,
      isPersistedRef,
      ledger,
      enqueue,
      onMutationRef,
    ],
  );

  const moveTask = useCallback(
    (
      sourceColId: string,
      destColId: string,
      sourceIndex: number,
      destIndex: number,
    ) => {
      const currentCols = columnsRef.current ?? [];

      const newCols = currentCols.map((col) => ({
        ...col,
        tasks: col.tasks.map((task) => ({ ...task })),
      }));

      const sourceCol = newCols.find((c) => c.id === sourceColId);
      const destCol = newCols.find((c) => c.id === destColId);
      if (!sourceCol || !destCol) return;

      if (!sourceCol.tasks[sourceIndex]) return;

      const [movedTask] = sourceCol.tasks.splice(sourceIndex, 1);
      if (!movedTask) return;

      movedTask.column_id = destColId;
      destCol.tasks.splice(destIndex, 0, movedTask);

      sourceCol.tasks.forEach((t, i) => {
        t.position = i;
      });
      destCol.tasks.forEach((t, i) => {
        t.position = i;
      });

      const allPositionUpdates: TaskPositionUpdate[] = [];
      const affected =
        sourceColId === destColId ? [destCol] : [sourceCol, destCol];
      for (const col of affected) {
        for (const task of col.tasks) {
          const update = {
            id: task.id,
            column_id: col.id,
            position: task.position,
          };
          allPositionUpdates.push(update);

          if (col.id.startsWith("local-")) continue;
          if (task.id.startsWith("local-")) continue;
        }
      }

      const intent: TaskMutationIntent = {
        id: generateUUID(),
        kind: "move",
        updates: allPositionUpdates,
      };
      const optimisticColumns = ledger.begin(intent, currentCols);
      setColumns(optimisticColumns);

      const includesLocalTask = allPositionUpdates.some((update) =>
        update.id.startsWith("local-"),
      );
      const includesPersistedTask = allPositionUpdates.some(
        (update) =>
          !update.id.startsWith("local-") &&
          !update.column_id?.startsWith("local-"),
      );
      if (
        !includesLocalTask &&
        (!isPersistedRef.current || !includesPersistedTask)
      ) {
        setColumns(
          ledger.settle(intent.id, optimisticColumns, {
            kind: "positions-saved",
            tasks: [],
          }),
        );
        return;
      }

      enqueue(async () => {
        try {
          if (!isPersistedRef.current) {
            setColumns(
              ledger.settle(intent.id, columnsRef.current ?? [], {
                kind: "positions-saved",
                tasks: [],
              }),
            );
            return;
          }
          const tasksToUpdate = intent.updates.filter(
            (update) =>
              !update.id.startsWith("local-") &&
              !update.column_id?.startsWith("local-"),
          );
          if (tasksToUpdate.length === 0) {
            setColumns(
              ledger.settle(intent.id, columnsRef.current ?? [], {
                kind: "positions-saved",
                tasks: [],
              }),
            );
            return;
          }
          const savedTasks = await updateTaskPositions(
            supabase,
            slug,
            tasksToUpdate,
          );
          setColumns(
            ledger.settle(intent.id, columnsRef.current ?? [], {
              kind: "positions-saved",
              tasks: savedTasks,
            }),
          );
          onMutationRef.current?.();
        } catch {
          setColumns(ledger.settle(intent.id, columnsRef.current ?? []));
          showMutationError("move task");
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
      ledger,
      onMutationRef,
    ],
  );

  return {
    addTask,
    editTask,
    removeTask,
    moveTask,
  };
}
