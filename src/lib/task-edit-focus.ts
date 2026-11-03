export interface TaskFocusOrigin {
  taskId: string;
  columnId: string;
  position: number;
  columnTitle: string;
}

export interface TaskFocusColumnSnapshot {
  id: string;
  title: string;
  taskIds: string[];
}

export interface TaskFocusCandidate {
  taskId: string;
  columnId: string;
  position: number;
}

export type TaskFocusTarget =
  | { kind: "task"; taskId: string; columnId: string }
  | { kind: "column"; columnId: string }
  | { kind: "board" }
  | null;

/** Preserve the task's source column, position, and label at the moment it opens. */
export function captureTaskFocusOrigin(
  taskId: string,
  fallbackColumnId: string,
  columns: TaskFocusColumnSnapshot[],
): TaskFocusOrigin {
  const sourceColumn = columns.find((column) =>
    column.taskIds.includes(taskId),
  );
  return {
    taskId,
    columnId: sourceColumn?.id ?? fallbackColumnId,
    position: sourceColumn?.taskIds.indexOf(taskId) ?? 0,
    columnTitle: sourceColumn?.title ?? "Columna",
  };
}

/** Choose the nearest still-valid control in the user's original board context. */
export function selectTaskFocusTarget(
  origin: TaskFocusOrigin | null,
  candidates: TaskFocusCandidate[],
  columnIds: string[],
  boardAvailable: boolean,
): TaskFocusTarget {
  if (!origin) return boardAvailable ? { kind: "board" } : null;

  const original = candidates.find(
    (candidate) =>
      candidate.taskId === origin.taskId &&
      candidate.columnId === origin.columnId,
  );
  if (original) {
    return {
      kind: "task",
      taskId: original.taskId,
      columnId: original.columnId,
    };
  }

  const nearestNeighbor = candidates
    .filter((candidate) => candidate.columnId === origin.columnId)
    .sort((left, right) => {
      const distance =
        Math.abs(left.position - origin.position) -
        Math.abs(right.position - origin.position);
      return distance || left.position - right.position;
    })[0];
  if (nearestNeighbor) {
    return {
      kind: "task",
      taskId: nearestNeighbor.taskId,
      columnId: nearestNeighbor.columnId,
    };
  }

  if (columnIds.includes(origin.columnId)) {
    return { kind: "column", columnId: origin.columnId };
  }
  return boardAvailable ? { kind: "board" } : null;
}
