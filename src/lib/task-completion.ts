import type { Task } from "@/lib/types";

export function orderTasksByCompletion(tasks: Task[]): {
  pending: Task[];
  completed: Task[];
} {
  const pending: Task[] = [];
  const completed: Task[] = [];

  for (const task of tasks) {
    (task.is_completed ? completed : pending).push(task);
  }

  completed.sort((left, right) => {
    const leftTime = left.completed_at ? Date.parse(left.completed_at) : 0;
    const rightTime = right.completed_at ? Date.parse(right.completed_at) : 0;
    return rightTime - leftTime || left.id.localeCompare(right.id);
  });

  return { pending, completed };
}

export function pendingTaskMoveIndices(
  columnTasks: Task[],
  taskId: string,
  destinationPendingIndex: number,
): { sourceIndex: number; destinationIndex: number } | null {
  const sourceIndex = columnTasks.findIndex((task) => task.id === taskId);
  if (sourceIndex < 0 || columnTasks[sourceIndex]?.is_completed) return null;

  const afterRemoval = columnTasks.filter((task) => task.id !== taskId);
  const destinationIndex = pendingTaskInsertionIndex(
    afterRemoval,
    destinationPendingIndex,
  );
  return { sourceIndex, destinationIndex };
}

export function pendingTaskInsertionIndex(
  columnTasks: Task[],
  destinationPendingIndex: number,
): number {
  const pending = columnTasks.filter((task) => !task.is_completed);
  const targetIndex = Math.max(
    0,
    Math.min(destinationPendingIndex, pending.length),
  );
  const targetTask = pending[targetIndex];
  return targetTask
    ? columnTasks.findIndex((task) => task.id === targetTask.id)
    : pending.length > 0
      ? columnTasks.findIndex(
          (task) => task.id === pending[pending.length - 1]?.id,
        ) + 1
      : columnTasks.findIndex((task) => task.is_completed) < 0
        ? columnTasks.length
        : columnTasks.findIndex((task) => task.is_completed);
}

export type TaskCompletionChoice = "save" | "discard" | "cancel";
export type TaskCompletionSaveOutcome =
  | "confirmed"
  | "conflict"
  | "error"
  | "reconciliation";

/** A completion follows only an explicit discard or a confirmed field save. */
export function taskCompletionFollowUp(
  choice: TaskCompletionChoice,
  saveOutcome?: TaskCompletionSaveOutcome,
): "complete" | "none" {
  if (choice === "discard") return "complete";
  return choice === "save" && saveOutcome === "confirmed" ? "complete" : "none";
}
