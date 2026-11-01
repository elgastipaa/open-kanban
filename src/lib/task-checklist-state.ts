interface ChecklistProgressStep {
  id: string;
  text: string;
  is_completed: boolean;
  position: number;
  version: number;
}

interface ChecklistCompletionResult {
  status: string;
  operation_id: string;
  pending_steps_count?: number;
  checklist_version?: number;
}

export function getTaskChecklistProgress(
  steps: readonly ChecklistProgressStep[],
): { completedCount: number; totalCount: number; pendingCount: number } {
  const completedCount = steps.filter((step) => step.is_completed).length;
  return {
    completedCount,
    totalCount: steps.length,
    pendingCount: steps.length - completedCount,
  };
}

export function moveTaskChecklistStep(
  steps: readonly ChecklistProgressStep[],
  stepId: string,
  offset: number,
): ChecklistProgressStep[] {
  const sourceIndex = steps.findIndex((step) => step.id === stepId);
  if (sourceIndex < 0 || !Number.isInteger(offset) || offset === 0) {
    return [...steps];
  }
  const targetIndex = Math.min(
    Math.max(sourceIndex + offset, 0),
    steps.length - 1,
  );
  if (targetIndex === sourceIndex) return [...steps];

  const reordered = [...steps];
  const [moved] = reordered.splice(sourceIndex, 1);
  reordered.splice(targetIndex, 0, moved);
  return reordered.map((step, position) => ({ ...step, position }));
}

export interface TaskChecklistCompletionReview {
  operationId: string;
  pendingStepsCount: number;
  checklistVersion: number;
}

export function getTaskChecklistCompletionReview(
  result: ChecklistCompletionResult,
): TaskChecklistCompletionReview | null {
  if (
    (result.status !== "confirmation_required" &&
      result.status !== "conflict") ||
    result.pending_steps_count === undefined ||
    result.checklist_version === undefined
  ) {
    return null;
  }
  return {
    operationId: result.operation_id,
    pendingStepsCount: result.pending_steps_count,
    checklistVersion: result.checklist_version,
  };
}
