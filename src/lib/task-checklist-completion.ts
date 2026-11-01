import type { TaskChecklistCompletionReview } from "@/lib/task-checklist-state";
import type { TaskCompletionCommand } from "@/lib/types";

export function resolveTaskChecklistCompletionReview(
  command: TaskCompletionCommand,
  review: TaskChecklistCompletionReview,
  decision: "accept" | "cancel",
): TaskCompletionCommand | null {
  if (decision === "cancel") return null;
  if (!command.is_completed || command.operation_id !== review.operationId) {
    return null;
  }
  return {
    ...command,
    confirmed_checklist_version: review.checklistVersion,
  };
}
