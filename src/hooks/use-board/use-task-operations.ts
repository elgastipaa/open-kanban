import type { SupabaseClient } from "@supabase/supabase-js";
import { useCallback, useRef } from "react";
import { toast } from "sonner";
import {
  createColumn,
  createTask,
  deleteTask as dbDeleteTask,
  getFullBoard,
  getFullBoardForTaskEdit,
  reconcileTaskCreation,
  TaskCaptureError,
  TaskEditError,
  TaskOrderError,
  updateTask,
  updateTaskPositions,
} from "@/lib/db";
import { getSessionEpoch } from "@/lib/supabase/client";
import { prepareTaskOrderMove } from "@/lib/task-order";
import type {
  Board,
  ColumnWithTasks,
  CreateTaskPayload,
  Priority,
  Task,
  TaskEditCommand,
  TaskEditConflicts,
  TaskEditResult,
  TaskOrderResult,
} from "@/lib/types";
import { generateUUID } from "@/lib/utils";
import type {
  TaskMutationIntent,
  TaskMutationLedger,
} from "./task-mutation-ledger";
import { reconcileAuthorizedTaskOrder } from "./task-order-reconciliation";
import { showMutationError, showTaskVerificationError } from "./utils";

interface UseTaskOperationsProps {
  slug: string;
  supabase: SupabaseClient;
  columnsRef: React.RefObject<ColumnWithTasks[]>;
  setColumns: React.Dispatch<React.SetStateAction<ColumnWithTasks[]>>;
  isPersistedRef: React.RefObject<boolean>;
  onMutationRef: React.RefObject<(() => void) | undefined>;
  persistBoard: () => Promise<Board>;
  enqueue: (op: () => Promise<void>) => Promise<void>;
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
  const orderReconciliationRequiredRef = useRef(false);

  const reconcileCurrentTaskOrder = useCallback(
    async (
      sessionEpoch: number,
      rollbackColumns?: ColumnWithTasks[],
    ): Promise<boolean> => {
      orderReconciliationRequiredRef.current = true;
      if (rollbackColumns) setColumns(rollbackColumns);
      const latestColumns = await reconcileAuthorizedTaskOrder({
        readBoard: () => getFullBoardForTaskEdit(supabase, slug),
        ledger,
        sessionEpoch,
        getCurrentSessionEpoch: getSessionEpoch,
        onAccessLost,
        isAccessDenied: (error) =>
          error instanceof TaskEditError && error.reason === "access_denied",
      });
      if (!latestColumns) return false;
      setColumns(latestColumns);
      orderReconciliationRequiredRef.current = false;
      return true;
    },
    [ledger, onAccessLost, setColumns, slug, supabase],
  );

  const reconcileAfterTaskMutation = useCallback(
    async (action: "created" | "deleted"): Promise<void> => {
      const reconciled = await reconcileCurrentTaskOrder(getSessionEpoch());
      if (!reconciled) {
        toast.error(
          action === "created"
            ? "La tarea se guardó, pero el orden no se actualizó"
            : "La tarea se eliminó, pero el orden no se actualizó",
          {
            description:
              "Vuelve a cargar el tablero antes de mover otra tarea.",
          },
        );
      }
    },
    [reconcileCurrentTaskOrder],
  );

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
      const columnsWithoutTask = ledger.forgetTask(tempTaskId, deletedColumns);
      setColumns(columnsWithoutTask);
      await reconcileAfterTaskMutation("deleted");
      onMutationRef.current?.();
    },
    [
      columnsRef,
      ledger,
      onMutationRef,
      reconcileAfterTaskMutation,
      setColumns,
      slug,
      supabase,
    ],
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
            await reconcileAfterTaskMutation("created");
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
      reconcileAfterTaskMutation,
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
          const columnsWithoutTask = ledger.settle(
            intent.id,
            columnsRef.current ?? [],
            { kind: "task-deleted" },
          );
          setColumns(columnsWithoutTask);
          await reconcileAfterTaskMutation("deleted");
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
      reconcileAfterTaskMutation,
    ],
  );

  const moveTask = useCallback(
    (
      sourceColId: string,
      destColId: string,
      sourceIndex: number,
      destIndex: number,
    ): Promise<TaskOrderResult | null> => {
      const operationId = generateUUID();
      if (orderReconciliationRequiredRef.current) {
        return Promise.resolve({
          status: "unavailable",
          operation_id: operationId,
        });
      }
      const currentCols = columnsRef.current ?? [];
      const plan = prepareTaskOrderMove(
        currentCols,
        sourceColId,
        destColId,
        sourceIndex,
        destIndex,
        operationId,
      );
      if (!plan) return Promise.resolve(null);

      const intent: TaskMutationIntent = {
        id: operationId,
        kind: "move",
        updates: plan.optimisticUpdates,
        orderCommand: plan.command,
      };
      const optimisticColumns = ledger.begin(intent, currentCols);
      setColumns(optimisticColumns);

      const localSnapshots = () =>
        plan.command.moves
          .map((move) =>
            optimisticColumns.find((column) => column.id === move.column_id),
          )
          .filter((column): column is ColumnWithTasks => column !== undefined)
          .map((column) => ({
            id: column.id,
            task_order_version: column.task_order_version,
            tasks: column.tasks,
          }));

      if (!isPersistedRef.current) {
        setColumns(
          ledger.settle(intent.id, optimisticColumns, {
            kind: "positions-saved",
            tasks: [],
          }),
        );
        const snapshots = new Map(
          localSnapshots().map((snapshot) => [snapshot.id, snapshot]),
        );
        return Promise.resolve({
          status: "confirmed",
          operation_id: operationId,
          columns: [...snapshots.values()],
        });
      }

      return new Promise((resolve) => {
        const finish = (result: TaskOrderResult) => resolve(result);
        void enqueue(async () => {
          const rollback = () =>
            ledger.settle(intent.id, columnsRef.current ?? []);
          const reconcileUnconfirmedMove = async (
            reason: "uncertain" | "retryable" | "expired_unknown",
          ): Promise<TaskOrderResult> => {
            const reconciled = await reconcileCurrentTaskOrder(
              sessionEpoch,
              rollback(),
            );
            toast.error("No se pudo confirmar el movimiento", {
              description: reconciled
                ? "Actualizamos el tablero. Revisa el lugar antes de elegir de nuevo."
                : "No pudimos consultar el orden actual. El movimiento quedó detenido; vuelve a cargar el tablero.",
            });
            return reconciled
              ? { status: reason, operation_id: operationId }
              : { status: "unavailable", operation_id: operationId };
          };

          const command = intent.orderCommand;
          if (
            command.moves.some(
              (move) =>
                move.id.startsWith("local-") ||
                move.column_id.startsWith("local-") ||
                move.before_task_id?.startsWith("local-") ||
                move.after_task_id?.startsWith("local-"),
            ) ||
            Object.keys(command.expected_order_versions).some((id) =>
              id.startsWith("local-"),
            )
          ) {
            setColumns(rollback());
            showMutationError("move task");
            finish({ status: "unavailable", operation_id: operationId });
            return;
          }

          const sessionEpoch = getSessionEpoch();
          try {
            const result = await updateTaskPositions(supabase, slug, command);
            if (sessionEpoch !== getSessionEpoch()) {
              setColumns(rollback());
              onAccessLost();
              finish({ status: "access_denied", operation_id: operationId });
              return;
            }
            if (result.status === "confirmed") {
              const settled = ledger.settle(
                intent.id,
                columnsRef.current ?? [],
                {
                  kind: "positions-saved",
                  tasks: result.columns.flatMap((column) => column.tasks),
                },
              );
              const snapshotsById = new Map(
                result.columns.map((snapshot) => [snapshot.id, snapshot]),
              );
              setColumns(
                settled.map((column) => {
                  const snapshot = snapshotsById.get(column.id);
                  return snapshot
                    ? {
                        ...column,
                        task_order_version: Math.max(
                          column.task_order_version,
                          snapshot.task_order_version,
                        ),
                      }
                    : column;
                }),
              );
              onMutationRef.current?.();
              finish(result);
              return;
            }
            if (result.status === "conflict") {
              const reconciled = await reconcileCurrentTaskOrder(
                sessionEpoch,
                rollback(),
              );
              toast.error("El orden cambió", {
                description: reconciled
                  ? "Actualizamos las columnas afectadas. Revisa el lugar y vuelve a elegir el movimiento."
                  : "No pudimos consultar el orden actual. El movimiento quedó detenido; vuelve a cargar el tablero.",
              });
              finish(
                reconciled
                  ? result
                  : { status: "unavailable", operation_id: operationId },
              );
              return;
            }
            if (
              result.status === "expired_unknown" ||
              result.status === "retryable" ||
              result.status === "uncertain"
            ) {
              finish(await reconcileUnconfirmedMove(result.status));
              return;
            }
            setColumns(rollback());
            if (result.status === "access_denied") onAccessLost();
            else if (result.status === "rejected")
              showMutationError("move task");
            finish(result);
          } catch (error) {
            const reason =
              error instanceof TaskOrderError ? error.reason : "uncertain";
            if (reason === "access_denied") {
              setColumns(rollback());
              onAccessLost();
              finish({ status: "access_denied", operation_id: operationId });
              return;
            }
            if (
              reason === "uncertain" ||
              reason === "retryable" ||
              reason === "expired_unknown"
            ) {
              finish(await reconcileUnconfirmedMove(reason));
              return;
            }
            setColumns(rollback());
            showMutationError("move task");
            finish({ status: reason, operation_id: operationId });
          }
        });
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
      onAccessLost,
      reconcileCurrentTaskOrder,
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
