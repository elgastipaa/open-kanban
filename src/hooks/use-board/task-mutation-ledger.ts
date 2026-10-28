import type { ColumnWithTasks, Task, TaskPositionUpdate } from "@/lib/types";

type EditableTaskFields = Pick<Task, "title" | "description" | "priority">;

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
  private deletedTaskIds = new Set<string>();

  constructor(columns: ColumnWithTasks[]) {
    this.sync(columns, true);
  }

  sync(columns: ColumnWithTasks[], resetPending = false): ColumnWithTasks[] {
    if (resetPending) {
      this.pendingIntents = [];
      this.deletedTaskIds.clear();
    } else {
      const incomingIds = new Set(
        columns.flatMap((column) => column.tasks.map((task) => task.id)),
      );
      for (const taskId of this.confirmedTasks.keys()) {
        if (!incomingIds.has(taskId)) this.deletedTaskIds.add(taskId);
      }
      for (const taskId of incomingIds) this.deletedTaskIds.delete(taskId);
    }
    this.confirmedTasks = new Map(
      columns.flatMap((column) =>
        column.tasks.map((task) => [task.id, { ...task }] as const),
      ),
    );
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
    return this.project(columns);
  }

  replaceTaskId(
    oldId: string,
    task: Task,
    columns: ColumnWithTasks[],
  ): ColumnWithTasks[] {
    this.confirmedTasks.delete(oldId);
    this.deletedTaskIds.delete(oldId);
    this.deletedTaskIds.delete(task.id);
    this.confirmedTasks.set(task.id, { ...task });
    for (const intent of this.pendingIntents) {
      if (intent.kind === "move") {
        for (const update of intent.updates) {
          if (update.id === oldId) update.id = task.id;
        }
      } else if (intent.taskId === oldId) {
        intent.taskId = task.id;
      }
    }
    return this.project(columns);
  }

  forgetTask(taskId: string, columns: ColumnWithTasks[]): ColumnWithTasks[] {
    this.confirmedTasks.delete(taskId);
    this.deletedTaskIds.delete(taskId);
    const retained: TaskMutationIntent[] = [];
    for (const intent of this.pendingIntents) {
      if (intent.kind === "move") {
        const updates = intent.updates.filter((update) => update.id !== taskId);
        if (updates.length > 0) retained.push({ ...intent, updates });
        continue;
      }
      if (intent.taskId !== taskId) retained.push(intent);
    }
    this.pendingIntents = retained;
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
    const currentFieldsAreNewer =
      current !== undefined &&
      compareTimestamps(current.updated_at, task.updated_at) > 0;
    this.confirmedTasks.set(
      task.id,
      currentFieldsAreNewer
        ? {
            ...task,
            title: current.title,
            description: current.description,
            priority: current.priority,
            updated_at: current.updated_at,
          }
        : { ...task },
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
