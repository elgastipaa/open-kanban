import type { MyTaskEntry, MyTasksOrder } from "@/lib/types";

export function orderMyTaskEntries(
  entries: MyTaskEntry[],
  order: MyTasksOrder,
): MyTaskEntry[] {
  return [...entries].sort((left, right) => {
    if (left.task.is_completed !== right.task.is_completed) {
      return left.task.is_completed ? 1 : -1;
    }

    if (left.task.is_completed && right.task.is_completed) {
      const completionOrder = compareDescending(
        left.task.completed_at,
        right.task.completed_at,
      );
      if (completionOrder !== 0) return completionOrder;
    } else if (order === "due") {
      const dueOrder = compareNullableAscending(
        left.task.due_on,
        right.task.due_on,
      );
      if (dueOrder !== 0) return dueOrder;
    }

    const creationOrder = left.task.created_at.localeCompare(
      right.task.created_at,
    );
    return creationOrder || left.task.id.localeCompare(right.task.id);
  });
}

function compareNullableAscending(
  left: string | null,
  right: string | null,
): number {
  if (left === null && right === null) return 0;
  if (left === null) return 1;
  if (right === null) return -1;
  return left.localeCompare(right);
}

function compareDescending(left: string | null, right: string | null): number {
  if (left === null && right === null) return 0;
  if (left === null) return 1;
  if (right === null) return -1;
  return right.localeCompare(left);
}
