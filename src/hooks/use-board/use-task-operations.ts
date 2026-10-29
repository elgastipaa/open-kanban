import type { SupabaseClient } from "@supabase/supabase-js";
import { useCallback, useRef } from "react";
import {
  createColumn,
  createTask,
  deleteTask as dbDeleteTask,
  getFullBoard,
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
import { showMutationError, showTaskVerificationError } from "./utils";

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

type TaskCreationResolution = {
  deleteRequested: boolean;
  needsVerification: boolean;
  columns: ColumnWithTasks[];
} | null;

function includeTaskColumn(
  columns: ColumnWithTasks[],
  task: Task,
  authoritativeColumns: ColumnWithTasks[],
  ledger: TaskMutationLedger,
): ColumnWithTasks[] {
  if (ledger.columnWasDeleted(task.column_id)) {
    return columns.filter((column) => !ledger.columnWasDeleted(column.id));
  }
  if (columns.some((column) => column.id === task.column_id)) return columns;
  const authoritativeColumn = authoritativeColumns.find(
    (column) => column.id === task.column_id,
  );
  return authoritativeColumn
    ? [...columns, { ...authoritativeColumn, tasks: [task] }]
    : columns;
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

  const verifyTaskCreation = useCallback(
    async (
      tempTaskId: string,
      createdTask: Task,
      previousColumns: ColumnWithTasks[],
    ): Promise<TaskCreationResolution> => {
      const verificationSyncRevision = ledger.syncRevision;
      let latestBoard: Awaited<ReturnType<typeof getFullBoard>> = null;
      let verificationError: unknown;
      let verificationFailed = false;
      try {
        latestBoard = await getFullBoard(supabase, slug);
      } catch (error) {
        verificationFailed = true;
        verificationError = error;
      }
      const liveColumns = columnsRef.current ?? previousColumns;
      const discardConfirmedMissingTask = () => {
        const persistedTaskId = ledger.pendingTaskCreationId(tempTaskId);
        ledger.failTaskCreation(tempTaskId);
        let columnsAfterDelete = ledger.forgetTask(tempTaskId, liveColumns);
        if (persistedTaskId) {
          columnsAfterDelete = ledger.forgetTask(
            persistedTaskId,
            columnsAfterDelete,
          );
        }
        setColumns(columnsAfterDelete);
      };

      if (ledger.syncRevision !== verificationSyncRevision) {
        const liveTask = liveColumns
          .flatMap((column) => column.tasks)
          .find((task) => task.id === createdTask.id);
        if (!liveTask) {
          discardConfirmedMissingTask();
          return null;
        }
        const creation = ledger.completeTaskCreation(
          tempTaskId,
          liveTask,
          liveColumns,
          true,
        );
        setColumns(creation.columns);
        return creation;
      }

      if (verificationFailed) throw verificationError;

      if (!latestBoard) {
        discardConfirmedMissingTask();
        return null;
      }

      const latestTask = latestBoard.columns
        .flatMap((column) => column.tasks)
        .find((task) => task.id === createdTask.id);
      if (!latestTask) {
        discardConfirmedMissingTask();
        return null;
      }

      const verifiedColumns = includeTaskColumn(
        liveColumns,
        latestTask,
        latestBoard.columns,
        ledger,
      );
      const creation = ledger.completeTaskCreation(
        tempTaskId,
        latestTask,
        verifiedColumns,
        true,
      );
      setColumns(creation.columns);
      return creation;
    },
    [columnsRef, ledger, setColumns, slug, supabase],
  );

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

      ledger.beginTaskCreation(tempTask.id);
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
              setColumns(
                ledger.replaceColumnId(
                  oldColumnId,
                  newCol.id,
                  columnsRef.current ?? [],
                ),
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
          let creation = ledger.completeTaskCreation(
            tempTask.id,
            dbTask,
            current,
          );
          if (creation.needsVerification) {
            const retryVerification = () => {
              enqueue(async () => {
                if (ledger.pendingTaskCreationId(tempTask.id) !== dbTask.id) {
                  return;
                }
                try {
                  const resolution = await verifyTaskCreation(
                    tempTask.id,
                    dbTask,
                    columnsRef.current ?? [],
                  );
                  if (resolution) onMutationRef.current?.();
                } catch {
                  showTaskVerificationError(retryVerification);
                }
              });
            };
            try {
              const resolution = await verifyTaskCreation(
                tempTask.id,
                dbTask,
                current,
              );
              if (!resolution) return;
              creation = resolution;
            } catch {
              showTaskVerificationError(retryVerification);
              return;
            }
          }
          if (creation.deleteRequested) {
            const deleteIntent: TaskMutationIntent = {
              id: generateUUID(),
              kind: "delete",
              taskId: dbTask.id,
            };
            const optimisticDelete = ledger.begin(
              deleteIntent,
              creation.columns,
            );
            setColumns(optimisticDelete);
            try {
              await dbDeleteTask(supabase, slug, dbTask.id);
            } catch {
              const rolledBack = ledger.settle(
                deleteIntent.id,
                columnsRef.current ?? optimisticDelete,
              );
              setColumns(ledger.replaceTaskId(tempTask.id, dbTask, rolledBack));
              showMutationError("delete task");
              return;
            }
            const deletedColumns = ledger.settle(
              deleteIntent.id,
              columnsRef.current ?? optimisticDelete,
              { kind: "task-deleted" },
            );
            setColumns(ledger.forgetTask(tempTask.id, deletedColumns));
            onMutationRef.current?.();
            return;
          }

          setColumns(creation.columns);
          onMutationRef.current?.();
        } catch {
          // Rollback task addition
          const current = columnsRef.current ?? [];
          const creationWasDeleted = ledger.failTaskCreation(tempTask.id);
          setColumns(
            ledger.forgetTask(
              tempTask.id,
              current.map((column) => ({
                ...column,
                tasks: column.tasks.filter((task) => task.id !== tempTask.id),
              })),
            ),
          );
          if (!creationWasDeleted) showMutationError("add task");
        }
      });
    },
    [
      columnsRef,
      setColumns,
      ledger,
      verifyTaskCreation,
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
      if (taskId.startsWith("local-")) {
        ledger.requestTaskCreationDeletion(taskId);
      }
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
