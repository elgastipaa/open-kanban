import type { TaskEditDraft } from "@/lib/task-edit-workflow";

export interface PreservedTaskDraft {
  actorId: string;
  taskId: string;
  authEpoch: string | number;
  draft: TaskEditDraft;
}

export type TaskDraftRefreshOutcome =
  | { status: "pending" }
  | { status: "denied" | "unavailable" | "discarded" }
  | {
      status: "authorized";
      authEpoch: string | number;
      taskIds: readonly string[];
    };

export type TaskDraftResolution =
  | { status: "pending" | "discard" }
  | { status: "restore"; draft: TaskEditDraft };

export function captureTaskDraftForAuthorizationRefresh({
  actorId,
  taskId,
  authEpoch,
  draft,
  isDirty,
}: PreservedTaskDraft & { isDirty: boolean }): PreservedTaskDraft | null {
  if (!isDirty) return null;
  return {
    actorId,
    taskId,
    authEpoch,
    draft: { ...draft },
  };
}

export function resolveTaskDraftAfterAuthorizationRefresh({
  preserved,
  currentActorId,
  currentAuthEpoch,
  outcome,
}: {
  preserved: PreservedTaskDraft | null;
  currentActorId: string;
  currentAuthEpoch: string | number;
  outcome: TaskDraftRefreshOutcome;
}): TaskDraftResolution {
  if (
    preserved === null ||
    preserved.actorId !== currentActorId ||
    String(preserved.authEpoch) !== String(currentAuthEpoch)
  ) {
    return { status: "discard" };
  }

  if (outcome.status === "pending") return { status: "pending" };
  if (outcome.status !== "authorized") return { status: "discard" };
  if (
    String(outcome.authEpoch) !== String(currentAuthEpoch) ||
    !outcome.taskIds.includes(preserved.taskId)
  ) {
    return { status: "discard" };
  }

  return { status: "restore", draft: { ...preserved.draft } };
}
