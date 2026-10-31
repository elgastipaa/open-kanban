import type { SupabaseClient } from "@supabase/supabase-js";
import { useCallback, useRef } from "react";
import {
  createColumn,
  createTask,
  deleteTask as dbDeleteTask,
  getFullBoard,
  getFullBoardForTaskEdit,
  reconcileTaskCreation,
  TaskCaptureError,
  TaskEditError,
  updateTask,
  updateTaskPositions,
} from "@/lib/db";
import { getSessionEpoch } from "@/lib/supabase/client";
import type {
  Board,
  ColumnWithTasks,
  CreateTaskPayload,
  Priority,
  Task,
  TaskEditCommand,
  TaskEditConflicts,
  TaskEditResult,
  TaskPositionUpdate,
} from "@/lib/types";
import { generateUUID } from "@/lib/utils";
import type {
  TaskMutationIntent,
  TaskMutationLedger,
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
  onAccessLost: () => void;
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
  onAccessLost,
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
            true,
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

  const deleteCreatedTask = useCallback(
    async (tempTaskId: string, task: Task, columns: ColumnWithTasks[]) => {
      const deleteIntent: TaskMutationIntent = {
        id: generateUUID(),
        kind: "delete",
        taskId: task.id,
      };
      const optimisticDelete = ledger.begin(deleteIntent, columns);
      setColumns(optimisticDelete);
      try {
        await dbDeleteTask(supabase, slug, task.id);
      } catch {
        const rolledBack = ledger.settle(
          deleteIntent.id,
          columnsRef.current ?? optimisticDelete,
        );
        setColumns(ledger.restoreTaskAfterFailedDelete(task, rolledBack));
        showMutationError("delete task");
        return;
      }
      const deletedColumns = ledger.settle(
        deleteIntent.id,
        columnsRef.current ?? optimisticDelete,
        { kind: "task-deleted" },
      );
      setColumns(ledger.forgetTask(tempTaskId, deletedColumns));
      onMutationRef.current?.();
    },
    [columnsRef, ledger, onMutationRef, setColumns, slug, supabase],
  );

  const addTask = useCallback(
    (
      columnId: string,
      title: string,
      operationId: string,
      reconcileFirst = false,
      priority: Priority = "medium",
    ): Promise<void> => {
      return new Promise((resolve, reject) => {
        const currentCols = columnsRef.current ?? [];
        const col = currentCols.find((c) => c.id === columnId);
        if (!col) {
          reject(new TaskCaptureError("unavailable"));
          return;
        }
        const position = col.tasks.length;

        // Optimistic state is local only; the server assigns the real position.
        const tempTask: Task = {
          id: `local-${generateUUID()}`,
          column_id: columnId,
          title,
          description: null,
          priority,
          position,
          created_by: null,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
          field_versions: { title: 1, description: 1, priority: 1 },
        };

        ledger.beginTaskCreation(tempTask.id);
        setColumns((prev) =>
          prev.map((candidate) =>
            candidate.id === columnId
              ? { ...candidate, tasks: [...candidate.tasks, tempTask] }
              : candidate,
          ),
        );

        enqueue(async () => {
          try {
            // Ensure board exists
            const board = await persistBoard();
            let targetColumnId =
              localColumnIds.current.get(columnId) ?? columnId;

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
            };
            const dbTask = reconcileFirst
              ? await reconcileTaskCreation(
                  supabase,
                  slug,
                  operationId,
                  board.id,
                  payload,
                )
              : await createTask(
                  supabase,
                  slug,
                  operationId,
                  board.id,
                  payload,
                );

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
                    if (resolution?.deleteRequested) {
                      await deleteCreatedTask(
                        tempTask.id,
                        dbTask,
                        resolution.columns,
                      );
                    } else if (resolution) {
                      onMutationRef.current?.();
                    }
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
                if (!resolution) {
                  resolve();
                  return;
                }
                creation = resolution;
              } catch {
                showTaskVerificationError(retryVerification);
                throw new TaskCaptureError("uncertain");
              }
            }
            if (creation.deleteRequested) {
              await deleteCreatedTask(tempTask.id, dbTask, creation.columns);
              resolve();
              return;
            }

            setColumns(creation.columns);
            onMutationRef.current?.();
            resolve();
          } catch (error) {
            const current = columnsRef.current ?? [];
            ledger.failTaskCreation(tempTask.id);
            setColumns(
              ledger.forgetTask(
                tempTask.id,
                current.map((column) => ({
                  ...column,
                  tasks: column.tasks.filter((task) => task.id !== tempTask.id),
                })),
              ),
            );
            reject(error);
          }
        });
      });
    },
    [
      columnsRef,
      setColumns,
      ledger,
      verifyTaskCreation,
      deleteCreatedTask,
      enqueue,
      persistBoard,
      supabase,
      slug,
      onMutationRef,
    ],
  );

  const editTask = useCallback(
    async (command: TaskEditCommand): Promise<TaskEditResult> => {
      if (!isPersistedRef.current || command.id.startsWith("local-")) {
        throw new TaskEditError("unavailable");
      }
      const sessionEpoch = getSessionEpoch();
      try {
        const result = await updateTask(supabase, slug, command);
        if (sessionEpoch !== getSessionEpoch()) {
          throw new TaskEditError("stale_session");
        }
        if (result.status !== "confirmed" && result.status !== "conflict") {
          throw new TaskEditError(result.status);
        }

        const currentColumns = columnsRef.current ?? [];
        let authoritativeColumns = currentColumns;
        if (
          !currentColumns.some((column) => column.id === result.task.column_id)
        ) {
          const latestBoard = await getFullBoardForTaskEdit(supabase, slug);
          if (sessionEpoch !== getSessionEpoch()) {
            throw new TaskEditError("stale_session");
          }
          if (!latestBoard) throw new TaskEditError("access_denied");
          authoritativeColumns = latestBoard.columns;
        }
        const nextColumns = authoritativeColumns.map((column) => ({
          ...column,
          tasks: [
            ...column.tasks.filter((task) => task.id !== result.task.id),
            ...(column.id === result.task.column_id ? [result.task] : []),
          ],
        }));
        setColumns(ledger.sync(nextColumns));
        if (result.status === "confirmed") onMutationRef.current?.();
        return result;
      } catch (error) {
        if (
          error instanceof TaskEditError &&
          (error.reason === "expired_unknown" || error.reason === "conflict")
        ) {
          try {
            const latestBoard = await getFullBoardForTaskEdit(supabase, slug);
            if (sessionEpoch !== getSessionEpoch()) {
              throw new TaskEditError("stale_session");
            }
            if (!latestBoard) {
              throw new TaskEditError("access_denied");
            }
            const latestTask = latestBoard.columns
              .flatMap((column) => column.tasks)
              .find((candidate) => candidate.id === command.id);
            if (!latestTask) throw new TaskEditError("unavailable");

            setColumns(ledger.sync(latestBoard.columns));
            const conflicts: TaskEditConflicts = {};
            if (command.updates.title !== undefined) {
              conflicts.title = {
                current: latestTask.title,
                draft: command.updates.title,
                current_version: latestTask.field_versions.title,
              };
            }
            if (Object.hasOwn(command.updates, "description")) {
              conflicts.description = {
                current: latestTask.description,
                draft: command.updates.description ?? null,
                current_version: latestTask.field_versions.description,
              };
            }
            if (command.updates.priority !== undefined) {
              conflicts.priority = {
                current: latestTask.priority,
                draft: command.updates.priority,
                current_version: latestTask.field_versions.priority,
              };
            }
            return {
              status: "conflict",
              operation_id: command.operation_id,
              task: latestTask,
              conflicts,
            };
          } catch (reconcileError) {
            if (
              reconcileError instanceof TaskEditError &&
              (reconcileError.reason === "access_denied" ||
                reconcileError.reason === "stale_session")
            ) {
              onAccessLost();
              throw reconcileError;
            }
            throw error;
          }
        }
        if (
          error instanceof TaskEditError &&
          (error.reason === "access_denied" || error.reason === "stale_session")
        ) {
          onAccessLost();
        }
        throw error;
      }
    },
    [
      supabase,
      slug,
      columnsRef,
      setColumns,
      isPersistedRef,
      ledger,
      onMutationRef,
      onAccessLost,
    ],
  );

  const refreshTaskForEdit = useCallback(
    async (taskId: string): Promise<Task | null> => {
      const sessionEpoch = getSessionEpoch();
      let latestBoard: Awaited<ReturnType<typeof getFullBoardForTaskEdit>>;
      try {
        latestBoard = await getFullBoardForTaskEdit(supabase, slug);
      } catch (error) {
        if (
          error instanceof TaskEditError &&
          error.reason === "access_denied"
        ) {
          onAccessLost();
        }
        throw error;
      }
      if (sessionEpoch !== getSessionEpoch()) {
        onAccessLost();
        throw new TaskEditError("stale_session");
      }
      if (!latestBoard) {
        onAccessLost();
        return null;
      }
      setColumns(ledger.sync(latestBoard.columns));
      return (
        latestBoard.columns
          .flatMap((column) => column.tasks)
          .find((candidate) => candidate.id === taskId) ?? null
      );
    },
    [supabase, slug, setColumns, ledger, onAccessLost],
  );

  const removeTask = useCallback(
    (taskId: string) => {
      const pendingCreationDeleteRequested =
        taskId.startsWith("local-") &&
        ledger.requestTaskCreationDeletion(taskId);
      const intent: TaskMutationIntent = {
        id: generateUUID(),
        kind: "delete",
        taskId,
      };
      const optimisticColumns = ledger.begin(intent, columnsRef.current ?? []);
      setColumns(optimisticColumns);

      if (pendingCreationDeleteRequested) {
        ledger.hidePendingCreationDelete(intent.taskId);
        setColumns(ledger.settle(intent.id, optimisticColumns));
        return;
      }

      if (!isPersistedRef.current) {
        setColumns(
          ledger.settle(intent.id, optimisticColumns, { kind: "task-deleted" }),
        );
        return;
      }

      if (intent.taskId.startsWith("local-")) {
        ledger.hidePendingCreationDelete(intent.taskId);
        setColumns(ledger.settle(intent.id, optimisticColumns));
        return;
      }

      enqueue(async () => {
        try {
          await dbDeleteTask(supabase, slug, intent.taskId);
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
    refreshTaskForEdit,
    removeTask,
    moveTask,
  };
}
