import type { ColumnWithTasks } from "@/lib/types";
import type { TaskMutationLedger } from "./task-mutation-ledger";

interface ReconcileAuthorizedTaskOrderOptions {
  readBoard: () => Promise<{ columns: ColumnWithTasks[] } | null>;
  ledger: TaskMutationLedger;
  sessionEpoch: number;
  getCurrentSessionEpoch: () => number;
  onAccessLost: () => void;
  isAccessDenied: (error: unknown) => boolean;
}

/** Adopt an authorized board read and replay only the ledger's pending intents over it. */
export async function reconcileAuthorizedTaskOrder({
  readBoard,
  ledger,
  sessionEpoch,
  getCurrentSessionEpoch,
  onAccessLost,
  isAccessDenied,
}: ReconcileAuthorizedTaskOrderOptions): Promise<ColumnWithTasks[] | null> {
  try {
    const latestBoard = await readBoard();
    if (sessionEpoch !== getCurrentSessionEpoch() || !latestBoard) {
      onAccessLost();
      return null;
    }
    return ledger.sync(latestBoard.columns);
  } catch (error) {
    if (isAccessDenied(error)) onAccessLost();
    return null;
  }
}
