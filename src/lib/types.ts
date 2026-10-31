export type WebSocketStatus = "SUBSCRIBED" | "CHANNEL_ERROR" | "TIMED_OUT";

export type TShortcut = {
  keys: string[];
  action: string;
};

export type Priority = "low" | "medium" | "high" | "urgent";
export type TaskEditableField = "title" | "description" | "priority";
export type TaskFieldVersions = Record<TaskEditableField, number>;

export interface Board {
  id: string;
  slug: string;
  name: string;
  time_zone: string;
  role: "owner" | "collaborator";
  created_at: string;
  updated_at: string;
}

export interface Column {
  id: string;
  board_id: string;
  title: string;
  position: number;
  is_collapsed: boolean;
  task_order_version: number;
  created_at: string;
}

export interface Task {
  id: string;
  column_id: string;
  created_by?: string | null;
  title: string;
  description: string | null;
  priority: Priority;
  position: number;
  created_at: string;
  updated_at: string;
  field_versions: TaskFieldVersions;
  is_completed: boolean;
  completed_at: string | null;
  completion_version: number;
}

export type TaskEditableFields = Pick<Task, TaskEditableField>;
export type TaskFieldUpdates = Partial<TaskEditableFields>;

export interface TaskEditCommand {
  id: string;
  operation_id: string;
  updates: TaskFieldUpdates;
  expected_versions: Partial<TaskFieldVersions>;
}

export interface TaskEditFieldConflict {
  current: string | null;
  draft: string | null;
  current_version: number;
}

export type TaskEditConflicts = Partial<
  Record<TaskEditableField, TaskEditFieldConflict>
>;

export type TaskEditResult =
  | { status: "confirmed"; operation_id: string; task: Task }
  | {
      status: "conflict";
      operation_id: string;
      task: Task;
      conflicts: TaskEditConflicts;
    }
  | {
      status: "unavailable" | "retryable" | "expired_unknown";
      operation_id: string;
    };

export interface TaskCompletionCommand {
  id: string;
  operation_id: string;
  is_completed: boolean;
  expected_version: number;
}

export type TaskCompletionResult =
  | { status: "confirmed" | "conflict"; operation_id: string; task: Task }
  | {
      status: "unavailable" | "retryable" | "expired_unknown";
      operation_id: string;
    };

/** Column with its nested tasks, used for client-side board state */
export interface ColumnWithTasks extends Column {
  tasks: Task[];
}

/** Full board state used by the board component */
export interface BoardState {
  board: Board | null;
  columns: ColumnWithTasks[];
}

/** Payload for creating a new task */
export interface CreateTaskPayload {
  column_id: string;
  title: string;
  description?: string | null;
  priority?: Priority;
}

/** Payload for an idempotent, version-checked task field edit. */
export type UpdateTaskPayload = TaskEditCommand;

/** Position-only change made by dragging or mobile move controls. */
export interface TaskPositionUpdate {
  id: string;
  column_id?: string;
  position: number;
}

export interface TaskOrderMove {
  id: string;
  source_column_id: string;
  column_id: string;
  before_task_id: string | null;
  after_task_id: string | null;
}

export interface TaskOrderCommand {
  operation_id: string;
  moves: TaskOrderMove[];
  expected_order_versions: Record<string, number>;
}

export interface TaskOrderColumnSnapshot {
  id: string;
  task_order_version: number;
  tasks: Task[];
}

export type TaskOrderResult =
  | {
      status: "confirmed" | "conflict";
      operation_id: string;
      columns: TaskOrderColumnSnapshot[];
    }
  | { status: "retryable" | "expired_unknown"; operation_id: string }
  | {
      status: "uncertain" | "unavailable" | "rejected" | "access_denied";
      operation_id: string;
    };

/** Payload for creating a new column */
export interface CreateColumnPayload {
  board_id: string;
  title: string;
  position: number;
}

/** Payload for updating a column */
export interface UpdateColumnPayload {
  id: string;
  title?: string;
  position?: number;
  is_collapsed?: boolean;
}
