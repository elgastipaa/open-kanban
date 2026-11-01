import type { Board, ColumnWithTasks } from "@/lib/types";

export interface UseBoardOptions {
  /** Authenticated actor for in-memory, actor-scoped command reconciliation. */
  actorId: string;
  slug: string;
  initialBoard: Board;
  initialColumns: ColumnWithTasks[];
  authEpoch: string | number;
  /** Reconciles a confirmed local write through an authorized database read. */
  onMutation?: () => void;
  /** Called when a board command confirms that the current user lost access. */
  onAccessLost?: () => void;
}
