import type {
  Column,
  ColumnWithTasks,
  TaskOrderCommand,
  TaskPositionUpdate,
} from "@/lib/types";

export interface TaskOrderMovePlan {
  command: TaskOrderCommand;
  optimisticUpdates: TaskPositionUpdate[];
}

/** Keep task contents local while adopting monotonic order versions read from the server. */
export function mergeAuthoritativeOrderVersions(
  columns: ColumnWithTasks[],
  authoritativeColumns: Pick<Column, "id" | "task_order_version">[],
): ColumnWithTasks[] {
  const versionsById = new Map(
    authoritativeColumns.map(({ id, task_order_version }) => [
      id,
      task_order_version,
    ]),
  );
  return columns.map((column) => {
    const authoritativeVersion = versionsById.get(column.id);
    return authoritativeVersion === undefined
      ? column
      : {
          ...column,
          task_order_version: Math.max(
            column.task_order_version,
            authoritativeVersion,
          ),
        };
  });
}

/** Build a position-only command from the current visible order. */
export function prepareTaskOrderMove(
  columns: ColumnWithTasks[],
  sourceColumnId: string,
  destinationColumnId: string,
  sourceIndex: number,
  destinationIndex: number,
  operationId: string,
): TaskOrderMovePlan | null {
  const nextColumns = columns.map((column) => ({
    ...column,
    tasks: column.tasks.map((task) => ({ ...task })),
  }));
  const source = nextColumns.find((column) => column.id === sourceColumnId);
  const destination = nextColumns.find(
    (column) => column.id === destinationColumnId,
  );
  const task = source?.tasks[sourceIndex];
  if (!source || !destination || !task) return null;

  const [movedTask] = source.tasks.splice(sourceIndex, 1);
  if (!movedTask) return null;
  const insertionIndex = Math.max(
    0,
    Math.min(destinationIndex, destination.tasks.length),
  );
  movedTask.column_id = destination.id;
  destination.tasks.splice(insertionIndex, 0, movedTask);

  const touched =
    source.id === destination.id ? [destination] : [source, destination];
  for (const column of touched) {
    column.tasks.forEach((currentTask, position) => {
      currentTask.position = position;
    });
  }

  const destinationPosition = destination.tasks.indexOf(movedTask);
  const command: TaskOrderCommand = {
    operation_id: operationId,
    moves: [
      {
        id: task.id,
        source_column_id: source.id,
        column_id: destination.id,
        before_task_id: destination.tasks[destinationPosition - 1]?.id ?? null,
        after_task_id: destination.tasks[destinationPosition + 1]?.id ?? null,
      },
    ],
    expected_order_versions: Object.fromEntries(
      touched.map((column) => [column.id, column.task_order_version]),
    ),
  };

  return {
    command,
    optimisticUpdates: touched.flatMap((column) =>
      column.tasks.map((currentTask) => ({
        id: currentTask.id,
        column_id: column.id,
        position: currentTask.position,
      })),
    ),
  };
}
