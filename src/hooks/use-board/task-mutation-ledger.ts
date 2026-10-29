import type { ColumnWithTasks, Task, TaskPositionUpdate } from "@/lib/types";

type EditableTaskFields = Pick<Task, "title" | "description" | "priority">;
type PendingTaskCreation = {
  deleteRequested: boolean;
  persistedTaskId?: string;
  syncRevision: number;
};

export type TaskMutationIntent =
  | {
      id: string;
      kind: "edit";
      taskId: string;
      updates: Partial<EditableTaskFields>;
    }
  | {
      id: string;
      kind: "move";
      updates: TaskPositionUpdate[];
    }
  | {
      id: string;
      kind: "delete";
      taskId: string;
    };

export type TaskMutationResult =
  | { kind: "task-saved"; task: Task }
  | { kind: "positions-saved"; tasks: Task[] }
  | { kind: "task-deleted" };

function compareTimestamps(left: string, right: string): number {
  const millisecondDifference = Date.parse(left) - Date.parse(right);
  if (millisecondDifference !== 0) return millisecondDifference;

  const subMillisecondPart = (value: string) => {
    const fraction = /\.(\d+)(?:Z|[+-]\d{2}(?::?\d{2})?)?$/.exec(value)?.[1];
    return Number((fraction ?? "").padEnd(6, "0").slice(3, 6));
  };

  return subMillisecondPart(left) - subMillisecondPart(right);
}

/**
 * Keeps confirmed task rows separate from optimistic task intents. A failed
 * intent is discarded and the remaining intents are projected over confirmed
 * rows, so settling one request cannot restore a snapshot from before a newer
 * edit, move, or delete.
 */
export class TaskMutationLedger {
  private confirmedTasks = new Map<string, Task>();
  private pendingIntents: TaskMutationIntent[] = [];
  private pendingCreations = new Map<string, PendingTaskCreation>();
  private resolvedTaskIds = new Map<string, string>();
  private deletedTaskIds = new Set<string>();
  private deletedColumnIds = new Set<string>();
  private mutationRevision = 0;
  private boardSyncRevision = 0;

  get revision(): number {
    return this.mutationRevision;
  }

  get syncRevision(): number {
    return this.boardSyncRevision;
  }

  constructor(columns: ColumnWithTasks[]) {
    this.sync(columns, true);
  }

  beginTaskCreation(taskId: string): void {
    this.pendingCreations.set(taskId, {
      deleteRequested: false,
      syncRevision: this.boardSyncRevision,
    });
    this.mutationRevision += 1;
  }

  requestTaskCreationDeletion(taskId: string): boolean {
    const creation = this.pendingCreations.get(taskId);
    if (!creation) return false;
    creation.deleteRequested = true;
    this.mutationRevision += 1;
    return true;
  }

  pendingTaskCreationId(taskId: string): string | undefined {
    return this.pendingCreations.get(taskId)?.persistedTaskId;
  }

  markColumnDeleted(columnId: string): void {
    this.deletedColumnIds.add(columnId);
    this.mutationRevision += 1;
  }

  restoreColumnAfterFailedDelete(
    columnId: string,
    columns: ColumnWithTasks[],
  ): ColumnWithTasks[] {
    if (this.deletedColumnIds.delete(columnId)) this.mutationRevision += 1;
    return this.project(columns);
  }

  columnWasDeleted(columnId: string): boolean {
    return this.deletedColumnIds.has(columnId);
  }

  completeTaskCreation(
    taskId: string,
    task: Task,
    columns: ColumnWithTasks[],
    authoritativeTaskPresent = false,
  ): {
    deleteRequested: boolean;
    needsVerification: boolean;
    columns: ColumnWithTasks[];
  } {
    const creation = this.pendingCreations.get(taskId);
    const refreshObserved =
      creation !== undefined &&
      creation.syncRevision !== this.boardSyncRevision;
    if (creation?.deleteRequested) {
      this.resolveTaskId(taskId, task.id);
      this.pendingCreations.delete(taskId);
      this.mutationRevision += 1;
      return {
        deleteRequested: true,
        needsVerification: false,
        columns: this.project(columns),
      };
    }
    if (
      refreshObserved &&
      !authoritativeTaskPresent &&
      !columns.some((column) =>
        column.tasks.some((candidate) => candidate.id === task.id),
      )
    ) {
      if (creation) {
        creation.persistedTaskId = task.id;
        this.resolveTaskId(taskId, task.id);
      }
      this.mutationRevision += 1;
      return {
        deleteRequested: false,
        needsVerification: true,
        columns: this.project(columns),
      };
    }
    this.pendingCreations.delete(taskId);
    return {
      deleteRequested: false,
      needsVerification: false,
      columns: this.replaceTaskId(taskId, task, columns),
    };
  }

  failTaskCreation(taskId: string): boolean {
    const creation = this.pendingCreations.get(taskId);
    this.pendingCreations.delete(taskId);
    if (creation?.persistedTaskId) {
      for (const intent of this.pendingIntents) {
        if (intent.kind !== "move") continue;
        intent.updates = intent.updates.filter(
          (update) => update.id !== creation.persistedTaskId,
        );
      }
      this.pendingIntents = this.pendingIntents.filter((intent) =>
        intent.kind === "move"
          ? intent.updates.length > 0
          : intent.taskId !== creation.persistedTaskId,
      );
    }
    this.mutationRevision += 1;
    return creation?.deleteRequested ?? false;
  }

  sync(columns: ColumnWithTasks[], resetPending = false): ColumnWithTasks[] {
    this.boardSyncRevision += 1;
    const incomingColumns = columns;
    if (resetPending) {
      this.pendingIntents = [];
      this.resolvedTaskIds.clear();
      this.deletedTaskIds.clear();
      this.deletedColumnIds.clear();
    } else {
      columns = columns.filter(
        (column) => !this.deletedColumnIds.has(column.id),
      );
      const incomingIds = new Set(
        incomingColumns.flatMap((column) =>
          column.tasks.map((task) => this.resolveTaskIdFor(task.id)),
        ),
      );
      const missingIds = new Set(
        [...this.confirmedTasks.keys()].filter(
          (taskId) =>
            !incomingIds.has(taskId) && !this.hasPendingCreationFor(taskId),
        ),
      );
      for (const taskId of missingIds) {
        this.deletedTaskIds.add(taskId);
      }
      for (const taskId of incomingIds) this.deletedTaskIds.delete(taskId);
      if (missingIds.size > 0) {
        for (const intent of this.pendingIntents) {
          if (intent.kind !== "move") continue;
          intent.updates = intent.updates.filter(
            (update) => !missingIds.has(update.id),
          );
        }
        this.pendingIntents = this.pendingIntents.filter(
          (intent) => intent.kind !== "move" || intent.updates.length > 0,
        );
      }
    }
    this.confirmedTasks = new Map(
      incomingColumns.flatMap((column) =>
        column.tasks.map((task) => {
          const resolvedId = this.resolveTaskIdFor(task.id);
          return [
            resolvedId,
            resolvedId === task.id ? { ...task } : { ...task, id: resolvedId },
          ] as const;
        }),
      ),
    );
    this.mutationRevision += 1;
    return this.project(columns);
  }

  begin(
    intent: TaskMutationIntent,
    columns: ColumnWithTasks[],
  ): ColumnWithTasks[] {
    this.seedUntrackedTasks(columns);
    if (intent.kind === "move") {
      for (const update of intent.updates) {
        update.id = this.resolveTaskIdFor(update.id);
      }
    } else {
      intent.taskId = this.resolveTaskIdFor(intent.taskId);
    }
    this.pendingIntents.push(intent);
    return this.project(columns);
  }

  settle(
    id: string,
    columns: ColumnWithTasks[],
    saved?: TaskMutationResult,
  ): ColumnWithTasks[] {
    const intent = this.pendingIntents.find((candidate) => candidate.id === id);
    if (!intent) return this.project(columns);

    if (intent.kind === "edit" && saved?.kind === "task-saved") {
      this.confirmTask(saved.task);
    } else if (intent.kind === "move" && saved?.kind === "positions-saved") {
      if (saved.tasks.length === 0) {
        for (const update of intent.updates) {
          const task = this.confirmedTasks.get(update.id);
          if (task) {
            this.confirmedTasks.set(update.id, {
              ...task,
              column_id: update.column_id ?? task.column_id,
              position: update.position,
            });
          }
        }
      }
      for (const task of saved.tasks) {
        this.confirmTask(task);
      }
    } else if (intent.kind === "delete" && saved?.kind === "task-deleted") {
      this.confirmedTasks.delete(intent.taskId);
      this.deletedTaskIds.add(intent.taskId);
      columns = columns.map((column) => ({
        ...column,
        tasks: column.tasks.filter((task) => task.id !== intent.taskId),
      }));
      for (const candidate of this.pendingIntents) {
        if (candidate.kind !== "move") continue;
        candidate.updates = candidate.updates.filter(
          (update) => update.id !== intent.taskId,
        );
      }
      this.pendingIntents = this.pendingIntents.filter(
        (candidate) =>
          candidate.kind !== "move" || candidate.updates.length > 0,
      );
    }

    this.pendingIntents = this.pendingIntents.filter(
      (candidate) => candidate.id !== id,
    );
    this.mutationRevision += 1;
    return this.project(columns);
  }

  replaceTaskId(
    oldId: string,
    task: Task,
    columns: ColumnWithTasks[],
  ): ColumnWithTasks[] {
    const localTask = columns
      .flatMap((column) => column.tasks)
      .find((candidate) => candidate.id === oldId);
    const savedTask = localTask
      ? {
          ...task,
          title: localTask.title,
          description: localTask.description,
          priority: localTask.priority,
        }
      : task;
    this.confirmedTasks.delete(oldId);
    this.deletedTaskIds.delete(oldId);
    this.confirmTask(savedTask);
    this.resolveTaskId(oldId, task.id);
    this.mutationRevision += 1;
    const columnsWithSavedTask = columns.map((column) => ({
      ...column,
      tasks: column.tasks.map((candidate) =>
        candidate.id === oldId ? savedTask : candidate,
      ),
    }));
    return this.project(columnsWithSavedTask);
  }

  replaceColumnId(
    oldId: string,
    newId: string,
    columns: ColumnWithTasks[],
  ): ColumnWithTasks[] {
    for (const [taskId, task] of this.confirmedTasks) {
      if (task.column_id === oldId) {
        this.confirmedTasks.set(taskId, { ...task, column_id: newId });
      }
    }
    for (const intent of this.pendingIntents) {
      if (intent.kind !== "move") continue;
      for (const update of intent.updates) {
        if (update.column_id === oldId) update.column_id = newId;
      }
    }
    this.mutationRevision += 1;
    const remappedColumns = columns.map((column) => ({
      ...column,
      id: column.id === oldId ? newId : column.id,
      tasks: column.tasks.map((task) =>
        task.column_id === oldId ? { ...task, column_id: newId } : task,
      ),
    }));
    return this.project(remappedColumns);
  }

  forgetTask(
    taskId: string,
    columns: ColumnWithTasks[],
    confirmedMissing = false,
  ): ColumnWithTasks[] {
    this.confirmedTasks.delete(taskId);
    if (confirmedMissing) this.deletedTaskIds.add(taskId);
    else this.deletedTaskIds.delete(taskId);
    columns = columns.map((column) => ({
      ...column,
      tasks: column.tasks.filter((task) => task.id !== taskId),
    }));
    for (const intent of this.pendingIntents) {
      if (intent.kind === "move") {
        intent.updates = intent.updates.filter(
          (update) => update.id !== taskId,
        );
      }
    }
    this.pendingIntents = this.pendingIntents.filter((intent) =>
      intent.kind === "move"
        ? intent.updates.length > 0
        : intent.taskId !== taskId,
    );
    this.mutationRevision += 1;
    return this.project(columns);
  }

  private remapPendingTaskId(oldId: string, newId: string): void {
    for (const intent of this.pendingIntents) {
      if (intent.kind === "move") {
        for (const update of intent.updates) {
          if (update.id === oldId) update.id = newId;
        }
      } else if (intent.taskId === oldId) {
        intent.taskId = newId;
      }
    }
  }

  private resolveTaskId(oldId: string, newId: string): void {
    if (oldId === newId) return;
    this.resolvedTaskIds.set(oldId, newId);
    const oldTask = this.confirmedTasks.get(oldId);
    if (oldTask) {
      this.confirmedTasks.delete(oldId);
      this.confirmTask({ ...oldTask, id: newId });
    }
    if (this.deletedTaskIds.delete(oldId)) this.deletedTaskIds.add(newId);
    this.remapPendingTaskId(oldId, newId);
  }

  private resolveTaskIdFor(taskId: string): string {
    return this.resolvedTaskIds.get(taskId) ?? taskId;
  }

  private hasPendingCreationFor(taskId: string): boolean {
    for (const [temporaryId, creation] of this.pendingCreations) {
      if (temporaryId === taskId || creation.persistedTaskId === taskId) {
        return true;
      }
    }
    return false;
  }

  private seedUntrackedTasks(columns: ColumnWithTasks[]): void {
    for (const column of columns) {
      for (const task of column.tasks) {
        const resolvedId = this.resolveTaskIdFor(task.id);
        if (!this.confirmedTasks.has(resolvedId)) {
          this.confirmedTasks.set(
            resolvedId,
            resolvedId === task.id ? { ...task } : { ...task, id: resolvedId },
          );
        }
      }
    }
  }

  private confirmTask(task: Task): void {
    if (this.deletedTaskIds.has(task.id)) return;
    const current = this.confirmedTasks.get(task.id);
    const currentTaskIsNewer =
      current !== undefined &&
      compareTimestamps(current.updated_at, task.updated_at) > 0;
    this.confirmedTasks.set(
      task.id,
      currentTaskIsNewer ? { ...current } : { ...task },
    );
  }

  private project(columns: ColumnWithTasks[]): ColumnWithTasks[] {
    const currentTasks = new Map<string, Task>();
    for (const column of columns) {
      for (const task of column.tasks) {
        const resolvedId = this.resolveTaskIdFor(task.id);
        if (this.deletedTaskIds.has(resolvedId)) continue;
        currentTasks.set(
          resolvedId,
          resolvedId === task.id ? { ...task } : { ...task, id: resolvedId },
        );
      }
    }
    const pendingDeletes = new Set(
      this.pendingIntents
        .filter((intent) => intent.kind === "delete")
        .map((intent) => intent.taskId),
    );
    const columnIds = new Set(columns.map((column) => column.id));

    for (const [taskId, confirmed] of this.confirmedTasks) {
      if (
        !columnIds.has(confirmed.column_id) ||
        pendingDeletes.has(taskId) ||
        this.deletedTaskIds.has(taskId)
      ) {
        continue;
      }
      currentTasks.set(taskId, { ...confirmed });
    }

    for (const intent of this.pendingIntents) {
      if (intent.kind === "edit") {
        const task = currentTasks.get(intent.taskId);
        if (task) currentTasks.set(task.id, { ...task, ...intent.updates });
      } else if (intent.kind === "move") {
        for (const update of intent.updates) {
          const task = currentTasks.get(update.id);
          if (!task) continue;
          currentTasks.set(update.id, {
            ...task,
            column_id: update.column_id ?? task.column_id,
            position: update.position,
          });
        }
      } else {
        currentTasks.delete(intent.taskId);
      }
    }

    let order = 0;
    const orderedByColumn = new Map<string, { task: Task; order: number }[]>();
    for (const task of currentTasks.values()) {
      const tasks = orderedByColumn.get(task.column_id) ?? [];
      tasks.push({ task, order });
      orderedByColumn.set(task.column_id, tasks);
      order += 1;
    }

    return columns.map((column) => {
      const tasks = (orderedByColumn.get(column.id) ?? [])
        .sort(
          (left, right) =>
            left.task.position - right.task.position ||
            left.order - right.order,
        )
        .map(({ task }, position) => ({
          ...task,
          column_id: column.id,
          position,
        }));

      return { ...column, tasks };
    });
  }
}
