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
}

interface TaskPositionSnapshot {
  column_id: string;
  position: number;
  version: number;
  optimistic_column_id: string;
}

function restoreMovePositions(
  current: ColumnWithTasks[],
  snapshots: Map<string, TaskPositionSnapshot>,
  positionVersions: Map<string, number>,
): ColumnWithTasks[] {
  const columnIds = new Set(current.map((column) => column.id));
  const restorable = new Map<string, TaskPositionSnapshot>();

  for (const [taskId, snapshot] of snapshots) {
    if (
      positionVersions.get(taskId) === snapshot.version &&
      columnIds.has(snapshot.column_id)
    ) {
      restorable.set(taskId, snapshot);
    }
  }

  const tasksByColumn = new Map<
    string,
    { task: Task; position: number; order: number }[]
  >();
  let order = 0;

  for (const column of current) {
    for (const task of column.tasks) {
      const snapshot = restorable.get(task.id);
      // Deleting a sibling compacts indices without superseding the move.
      const shouldRestore =
        snapshot !== undefined &&
        task.column_id === snapshot.optimistic_column_id;
      const columnId = shouldRestore ? snapshot.column_id : column.id;
      const position = shouldRestore ? snapshot.position : task.position;
      const tasks = tasksByColumn.get(columnId) ?? [];
      tasks.push({ task, position, order });
      tasksByColumn.set(columnId, tasks);
      order += 1;
    }
  }

  return current.map((column) => {
    const tasks = (tasksByColumn.get(column.id) ?? []).sort(
      (left, right) =>
        left.position - right.position || left.order - right.order,
    );

    return {
      ...column,
      tasks: tasks.map(({ task }, position) => ({
        ...task,
        column_id: column.id,
        position,
      })),
    };
  });
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
}: UseTaskOperationsProps) {
  const taskEditVersions = useRef(new Map<string, number>());
  const taskPositionVersions = useRef(new Map<string, number>());

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
          let targetColumnId = columnId;

          // If the target column is still unpersisted local-, create it first
          if (columnId.startsWith("local-")) {
            const currentSnapshot = columnsRef.current ?? [];
            const targetCol = currentSnapshot.find((c) => c.id === columnId);
            if (targetCol) {
              const newCol = await createColumn(supabase, slug, {
                board_id: board.id,
                title: targetCol.title,
                position: targetCol.position,
              });
              targetColumnId = newCol.id;
              setColumns((prev) =>
                prev.map((c) =>
                  c.id === columnId ? { ...c, id: newCol.id } : c,
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

          setColumns((prev) =>
            prev.map((c) => ({
              ...c,
              tasks: c.tasks.map((t) => (t.id === tempTask.id ? dbTask : t)),
            })),
          );
          onMutationRef.current?.();
        } catch {
          // Rollback task addition
          setColumns((prev) =>
            prev.map((c) => ({
              ...c,
              tasks: c.tasks.filter((t) => t.id !== tempTask.id),
            })),
          );
          showMutationError("add task");
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
      const taskBeforeEdit = (columnsRef.current ?? [])
        .flatMap((col) => col.tasks)
        .find((task) => task.id === taskId);
      const previousTask = taskBeforeEdit ? { ...taskBeforeEdit } : undefined;
      const editVersion = (taskEditVersions.current.get(taskId) ?? 0) + 1;
      taskEditVersions.current.set(taskId, editVersion);
      setColumns((prev) =>
        prev.map((col) => ({
          ...col,
          tasks: col.tasks.map((t) =>
            t.id === taskId ? { ...t, ...updates } : t,
          ),
        })),
      );

      if (!isPersistedRef.current || taskId.startsWith("local-")) return;

      enqueue(async () => {
        try {
          await updateTask(supabase, slug, { id: taskId, ...updates });
          onMutationRef.current?.();
        } catch {
          setColumns((current) => {
            if (
              !previousTask ||
              taskEditVersions.current.get(taskId) !== editVersion
            ) {
              return current;
            }

            return current.map((col) => ({
              ...col,
              tasks: col.tasks.map((task) =>
                task.id === taskId
                  ? {
                      ...task,
                      title: previousTask.title,
                      description: previousTask.description,
                      priority: previousTask.priority,
                      updated_at: previousTask.updated_at,
                    }
                  : task,
              ),
            }));
          });
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
      enqueue,
      onMutationRef,
    ],
  );

  const removeTask = useCallback(
    (taskId: string) => {
      const snapshot = columnsRef.current ?? [];
      taskEditVersions.current.delete(taskId);
      taskPositionVersions.current.delete(taskId);
      // Keep the move version for surviving siblings so rollback can reinsert
      // the moved task into their original order after this deletion.
      setColumns((prev) =>
        prev.map((col) => ({
          ...col,
          tasks: col.tasks
            .filter((t) => t.id !== taskId)
            .map((t, i) => ({ ...t, position: i })),
        })),
      );

      if (!isPersistedRef.current || taskId.startsWith("local-")) return;

      enqueue(async () => {
        try {
          await dbDeleteTask(supabase, slug, taskId);
          onMutationRef.current?.();
        } catch {
          setColumns(snapshot);
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

      const positionSnapshot = new Map<string, TaskPositionSnapshot>();
      for (const column of currentCols) {
        if (column.id !== sourceColId && column.id !== destColId) continue;
        for (const task of column.tasks) {
          const version = (taskPositionVersions.current.get(task.id) ?? 0) + 1;
          taskPositionVersions.current.set(task.id, version);
          positionSnapshot.set(task.id, {
            column_id: column.id,
            position: task.position,
            version,
            optimistic_column_id: column.id,
          });
        }
      }

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

      setColumns(newCols);

      if (!isPersistedRef.current) return;

      const tasksToUpdate: TaskPositionUpdate[] = [];
      const editVersionsAtMove = new Map<string, number>();
      const affected =
        sourceColId === destColId ? [destCol] : [sourceCol, destCol];
      for (const col of affected) {
        for (const task of col.tasks) {
          const snapshot = positionSnapshot.get(task.id);
          if (snapshot) {
            snapshot.optimistic_column_id = col.id;
          }
        }

        if (col.id.startsWith("local-")) continue;
        for (const task of col.tasks) {
          if (task.id.startsWith("local-")) continue;
          tasksToUpdate.push({
            id: task.id,
            column_id: col.id,
            position: task.position,
          });
          editVersionsAtMove.set(
            task.id,
            taskEditVersions.current.get(task.id) ?? 0,
          );
        }
      }

      if (tasksToUpdate.length > 0) {
        enqueue(async () => {
          try {
            const savedTasks = await updateTaskPositions(
              supabase,
              slug,
              tasksToUpdate,
            );
            const savedById = new Map(
              savedTasks.map((task) => [task.id, task]),
            );
            setColumns((current) =>
              current.map((col) => ({
                ...col,
                tasks: col.tasks.map((task) => {
                  const savedTask = savedById.get(task.id);
                  if (!savedTask) return task;

                  const editedAfterMoveStarted =
                    (taskEditVersions.current.get(task.id) ?? 0) >
                    (editVersionsAtMove.get(task.id) ?? 0);
                  if (editedAfterMoveStarted) return task;

                  return {
                    ...task,
                    title: savedTask.title,
                    description: savedTask.description,
                    priority: savedTask.priority,
                    updated_at: savedTask.updated_at,
                  };
                }),
              })),
            );
            onMutationRef.current?.();
          } catch {
            setColumns((current) =>
              restoreMovePositions(
                current,
                positionSnapshot,
                taskPositionVersions.current,
              ),
            );
            showMutationError("move task");
          }
        });
      }
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
    addTask,
    editTask,
    removeTask,
    moveTask,
  };
}
