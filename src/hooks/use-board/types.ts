import type { Board, ColumnWithTasks } from "@/lib/types";

export interface UseBoardOptions {
  slug: string;
  initialBoard: Board;
  initialColumns: ColumnWithTasks[];
  /** Called after every DB write - used to trigger broadcast sync */
  onMutation?: () => void;
  /** Called when a board command confirms that the current user lost access. */
  onAccessLost?: () => void;
}
