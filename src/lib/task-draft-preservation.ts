import type { TaskEditDraft } from "@/lib/task-edit-workflow";
import type {
  TaskEditableField,
  TaskEditConflicts,
  TaskFieldVersions,
} from "@/lib/types";

export interface PreservedTaskDraft {
  actorId: string;
  taskId: string;
  authEpoch: string | number;
  draft: Partial<TaskEditDraft>;
  dirtyFields: readonly TaskEditableField[];
  baseVersions: Partial<TaskFieldVersions>;
}

export interface TaskDraftSnapshot {
  title: string;
  description: string | null;
  priority: TaskEditDraft["priority"];
  due_on: string | null;
  field_versions: TaskFieldVersions;
}

export type TaskDraftRefreshOutcome =
  | { status: "pending" }
  | { status: "denied" | "unavailable" | "discarded" | "retryable" }
  | {
      status: "authorized";
      authEpoch: string | number;
      taskIds: readonly string[];
    };

export type TaskDraftResolution =
  | { status: "pending" | "discard" }
  | { status: "restore"; preserved: PreservedTaskDraft };

export function captureTaskDraftForAuthorizationRefresh({
  actorId,
  taskId,
  authEpoch,
  draft,
  dirtyFields,
  baseVersions,
}: {
  actorId: string;
  taskId: string;
  authEpoch: string | number;
  draft: TaskEditDraft;
  dirtyFields: readonly TaskEditableField[];
  baseVersions: TaskFieldVersions;
}): PreservedTaskDraft | null {
  if (dirtyFields.length === 0) return null;

  const preservedDraft: Partial<TaskEditDraft> = {};
  const preservedVersions: Partial<TaskFieldVersions> = {};
  const uniqueFields = [...new Set(dirtyFields)];
  for (const field of uniqueFields) {
    switch (field) {
      case "title":
        preservedDraft.title = draft.title;
        break;
      case "description":
        preservedDraft.description = draft.description;
        break;
      case "priority":
        preservedDraft.priority = draft.priority;
        break;
      case "due_on":
        preservedDraft.due_on = draft.due_on;
        break;
    }
    preservedVersions[field] = baseVersions[field];
  }

  return {
    actorId,
    taskId,
    authEpoch,
    draft: preservedDraft,
    dirtyFields: uniqueFields,
    baseVersions: preservedVersions,
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

  if (outcome.status === "pending" || outcome.status === "retryable") {
    return { status: "pending" };
  }
  if (outcome.status !== "authorized") return { status: "discard" };
  if (
    String(outcome.authEpoch) !== String(currentAuthEpoch) ||
    !outcome.taskIds.includes(preserved.taskId)
  ) {
    return { status: "discard" };
  }

  return {
    status: "restore",
    preserved: {
      ...preserved,
      dirtyFields: [...preserved.dirtyFields],
      draft: { ...preserved.draft },
      baseVersions: { ...preserved.baseVersions },
    },
  };
}

export function rebasePreservedTaskDraft(
  snapshot: TaskDraftSnapshot,
  preserved: PreservedTaskDraft,
): { draft: TaskEditDraft; conflicts: TaskEditConflicts } {
  const draft: TaskEditDraft = {
    title: snapshot.title,
    description: snapshot.description ?? "",
    priority: snapshot.priority,
    due_on: snapshot.due_on ?? "",
  };
  const conflicts: TaskEditConflicts = {};

  for (const field of preserved.dirtyFields) {
    const localValue = preserved.draft[field];
    if (localValue === undefined) continue;

    switch (field) {
      case "title":
        draft.title = localValue;
        if (
          preserved.baseVersions.title !== undefined &&
          preserved.baseVersions.title !== snapshot.field_versions.title &&
          localValue.trim() !== snapshot.title
        ) {
          conflicts.title = {
            current: snapshot.title,
            draft: localValue,
            current_version: snapshot.field_versions.title,
          };
        }
        break;
      case "description":
        draft.description = localValue;
        if (
          preserved.baseVersions.description !== undefined &&
          preserved.baseVersions.description !==
            snapshot.field_versions.description &&
          (localValue.trim() || null) !== snapshot.description
        ) {
          conflicts.description = {
            current: snapshot.description,
            draft: localValue,
            current_version: snapshot.field_versions.description,
          };
        }
        break;
      case "priority":
        draft.priority = localValue as TaskEditDraft["priority"];
        if (
          preserved.baseVersions.priority !== undefined &&
          preserved.baseVersions.priority !== snapshot.field_versions.priority &&
          localValue !== snapshot.priority
        ) {
          conflicts.priority = {
            current: snapshot.priority,
            draft: localValue,
            current_version: snapshot.field_versions.priority,
          };
        }
        break;
      case "due_on":
        draft.due_on = localValue;
        if (
          preserved.baseVersions.due_on !== undefined &&
          preserved.baseVersions.due_on !== snapshot.field_versions.due_on &&
          (localValue || null) !== snapshot.due_on
        ) {
          conflicts.due_on = {
            current: snapshot.due_on,
            draft: localValue,
            current_version: snapshot.field_versions.due_on,
          };
        }
        break;
    }
  }

  return { draft, conflicts };
}

export interface TaskDraftAuthorizationRefreshContext {
  requestActorId: string;
  currentActorId: string;
  requestAuthEpoch: string | number;
  currentAuthEpoch: string | number;
  requestSessionEpoch: number;
  currentSessionEpoch: number;
  requestSignal: AbortSignal;
  isMounted: boolean;
  isCurrentGeneration: boolean;
}

export function isTaskDraftAuthorizationRefreshCurrent({
  requestActorId,
  currentActorId,
  requestAuthEpoch,
  currentAuthEpoch,
  requestSessionEpoch,
  currentSessionEpoch,
  requestSignal,
  isMounted,
  isCurrentGeneration,
}: TaskDraftAuthorizationRefreshContext): boolean {
  return (
    isMounted &&
    isCurrentGeneration &&
    requestActorId === currentActorId &&
    String(requestAuthEpoch) === String(currentAuthEpoch) &&
    requestSessionEpoch === currentSessionEpoch &&
    !requestSignal.aborted
  );
}

export function shouldRetryTaskDraftAuthorizationRefresh({
  preserved,
  outcome,
  ...context
}: TaskDraftAuthorizationRefreshContext & {
  preserved: PreservedTaskDraft | null;
  outcome: TaskDraftRefreshOutcome;
}): boolean {
  return (
    isTaskDraftAuthorizationRefreshCurrent(context) &&
    preserved !== null &&
    (outcome.status === "discarded" || outcome.status === "retryable") &&
    preserved.actorId === context.currentActorId &&
    String(preserved.authEpoch) === String(context.currentAuthEpoch)
  );
}
