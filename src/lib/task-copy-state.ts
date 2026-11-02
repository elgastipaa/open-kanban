import type { TaskCopyPreview } from "@/lib/db/task-copy";

export interface TaskCopyFormState {
  preview: TaskCopyPreview | null;
  title: string;
  targetColumnId: string;
  reviewRequired: boolean;
}

export function emptyTaskCopyFormState(): TaskCopyFormState {
  return {
    preview: null,
    title: "",
    targetColumnId: "",
    reviewRequired: false,
  };
}

export function receiveTaskCopyPreview(
  state: TaskCopyFormState,
  preview: TaskCopyPreview,
): TaskCopyFormState {
  const previousHash = state.preview?.source_hash;
  const changed =
    previousHash !== undefined && previousHash !== preview.source_hash;

  return {
    preview,
    title: state.preview ? state.title : (preview.title ?? ""),
    targetColumnId: state.preview
      ? state.targetColumnId
      : (preview.target_column_id ?? ""),
    reviewRequired: state.reviewRequired || changed,
  };
}

export function acknowledgeTaskCopyPreview(
  state: TaskCopyFormState,
): TaskCopyFormState {
  return { ...state, reviewRequired: false };
}

export function canCreateTaskCopy(state: TaskCopyFormState): boolean {
  return Boolean(
    state.preview?.status === "available" &&
      state.preview.source_hash &&
      state.title.trim() &&
      state.targetColumnId &&
      !state.reviewRequired,
  );
}
