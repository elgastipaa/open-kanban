import type { ColumnWithTasks, Task, TaskPositionUpdate } from "@/lib/types";

type EditableTaskFields = Pick<Task, "title" | "description" | "priority">;
type PendingTaskCreation = { deleteRequested: boolean };

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
  private deletedTaskIds = new Set<string>();
  private mutationRevision = 0;

  get revision(): number {
    return this.mutationRevision;
  }

  constructor(columns: ColumnWithTasks[]) {
    this.sync(columns, true);
  }

  beginTaskCreation(taskId: string): void {
    this.pendingCreations.set(taskId, { deleteRequested: false });
    this.mutationRevision += 1;
  }

  requestTaskCreationDeletion(taskId: string): boolean {
    const creation = this.pendingCreations.get(taskId);
    if (!creation) return false;
    creation.deleteRequested = true;
    this.mutationRevision += 1;
    return true;
  }

  completeTaskCreation(
    taskId: string,
    task: Task,
    columns: ColumnWithTasks[],
  ): { deleteRequested: boolean; columns: ColumnWithTasks[] } {
    const creation = this.pendingCreations.get(taskId);
    this.pendingCreations.delete(taskId);
    if (creation?.deleteRequested) {
      this.mutationRevision += 1;
      return { deleteRequested: true, columns: this.project(columns) };
    }
    return {
      deleteRequested: false,
      columns: this.replaceTaskId(taskId, task, columns),
    };
  }

  failTaskCreation(taskId: string): boolean {
    const creation = this.pendingCreations.get(taskId);
    this.pendingCreations.delete(taskId);
    this.mutationRevision += 1;
    return creation?.deleteRequested ?? false;
  }

  sync(columns: ColumnWithTasks[], resetPending = false): ColumnWithTasks[] {
    if (resetPending) {
      this.pendingIntents = [];
      this.deletedTaskIds.clear();
    } else {
      const incomingIds = new Set(
        columns.flatMap((column) => column.tasks.map((task) => task.id)),
      );
      const missingIds = new Set(
        [...this.confirmedTasks.keys()].filter(
          (taskId) =>
            !incomingIds.has(taskId) && !this.pendingCreations.has(taskId),
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
      columns.flatMap((column) =>
        column.tasks.map((task) => [task.id, { ...task }] as const),
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
    for (const intent of this.pendingIntents) {
      if (intent.kind === "move") {
        for (const update of intent.updates) {
          if (update.id === oldId) update.id = task.id;
        }
      } else if (intent.taskId === oldId) {
        intent.taskId = task.id;
      }
    }
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

  forgetTask(taskId: string, columns: ColumnWithTasks[]): ColumnWithTasks[] {
    this.confirmedTasks.delete(taskId);
    this.deletedTaskIds.delete(taskId);
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

  private seedUntrackedTasks(columns: ColumnWithTasks[]): void {
    for (const column of columns) {
      for (const task of column.tasks) {
        if (!this.confirmedTasks.has(task.id)) {
          this.confirmedTasks.set(task.id, { ...task });
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
    const currentTasks = new Map(
      columns.flatMap((column) =>
        column.tasks.map((task) => [task.id, { ...task }] as const),
      ),
    );
    const pendingDeletes = new Set(
      this.pendingIntents
        .filter((intent) => intent.kind === "delete")
        .map((intent) => intent.taskId),
    );
    const columnIds = new Set(columns.map((column) => column.id));

    for (const [taskId, confirmed] of this.confirmedTasks) {
      if (!columnIds.has(confirmed.column_id) || pendingDeletes.has(taskId)) {
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
