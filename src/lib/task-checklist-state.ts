import type { TaskChecklistCommand } from "./types";

interface ChecklistProgressStep {
  id: string;
  text: string;
  is_completed: boolean;
  position: number;
  version: number;
}

export type TaskChecklistMutationOutcome =
  | "confirmed"
  | "resolved"
  | "unresolved"
  | "access_lost";

/** Lives for one authorized board workspace, so pending payloads stay in memory. */
export class TaskChecklistAddOperationStore {
  private readonly commands = new Map<string, TaskChecklistCommand>();
  private readonly actorId: string;
  private readonly boardSlug: string;

  constructor(actorId: string, boardSlug: string) {
    this.actorId = actorId;
    this.boardSlug = boardSlug;
  }

  private key(taskId: string): string {
    return `${this.actorId}:${this.boardSlug}:${taskId}`;
  }

  get(taskId: string): TaskChecklistCommand | null {
    return this.commands.get(this.key(taskId)) ?? null;
  }

  set(command: TaskChecklistCommand): void {
    this.commands.set(this.key(command.id), command);
  }

  clear(taskId: string): void {
    this.commands.delete(this.key(taskId));
  }

  clearAll(): void {
    this.commands.clear();
  }
}

export function getOrCreateTaskChecklistAddCommand(
  pending: TaskChecklistCommand | null,
  taskId: string,
  text: string,
  operationId: string,
): TaskChecklistCommand {
  return (
    pending ?? {
      id: taskId,
      operation_id: operationId,
      command: { action: "add", text },
    }
  );
}

export function settleTaskChecklistAddCommand(
  pending: TaskChecklistCommand | null,
  outcome: TaskChecklistMutationOutcome,
): TaskChecklistCommand | null {
  return outcome === "confirmed" ||
    outcome === "resolved" ||
    outcome === "access_lost"
    ? null
    : pending;
}

export function settleTaskChecklistAddOperation(
  operations: TaskChecklistAddOperationStore,
  pending: TaskChecklistCommand | null,
  outcome: TaskChecklistMutationOutcome,
): TaskChecklistCommand | null {
  const settled = settleTaskChecklistAddCommand(pending, outcome);
  if (outcome === "access_lost") {
    operations.clearAll();
  } else if (settled) {
    operations.set(settled);
  } else if (pending) {
    operations.clear(pending.id);
  }
  return settled;
}

export function shouldClearTaskChecklistAddText(
  outcome: TaskChecklistMutationOutcome,
): boolean {
  return outcome === "confirmed" || outcome === "access_lost";
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
