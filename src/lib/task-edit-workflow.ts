export type TaskEditDraft = {
  title: string;
  description: string;
  priority: "low" | "medium" | "high" | "urgent";
  due_on: string;
};

export type TaskEditOperation = {
  id: string;
  operation_id: string;
  updates: Partial<{
    title: string;
    description: string | null;
    priority: TaskEditDraft["priority"];
    due_on: string | null;
  }>;
  expected_versions: Partial<
    Record<"title" | "description" | "priority" | "due_on", number>
  >;
};

export type TaskEditWorkflowStatus =
  | "idle"
  | "saving"
  | "saved"
  | "error"
  | "conflict";

export type TaskEditSaveIntent = "stay" | "close" | "delete";
export type TaskEditSaveOutcome =
  | "confirmed"
  | "conflict"
  | "error"
  | "reconciliation";
export type TaskEditSaveFollowUp = "none" | "close" | "confirm-delete";
export type TaskMoveChoice = "save" | "discard" | "cancel";

/** A requested move follows only an explicit discard or a confirmed save. */
export function taskMoveFollowUp(
  choice: TaskMoveChoice,
  saveOutcome?: TaskEditSaveOutcome,
): "move" | "none" {
  if (choice === "discard") return "move";
  return choice === "save" && saveOutcome === "confirmed" ? "move" : "none";
}

/** Destructive follow-up is allowed only after the save itself is confirmed. */
export function taskEditSaveFollowUp(
  intent: TaskEditSaveIntent,
  outcome: TaskEditSaveOutcome,
): TaskEditSaveFollowUp {
  if (outcome !== "confirmed") return "none";
  if (intent === "close") return "close";
  if (intent === "delete") return "confirm-delete";
  return "none";
}

export interface TaskEditWorkflowState {
  draft: TaskEditDraft;
  status: TaskEditWorkflowStatus;
  error: string | null;
  operation: TaskEditOperation | null;
}

export function createTaskEditWorkflow(
  draft: TaskEditDraft,
): TaskEditWorkflowState {
  return { draft, status: "idle", error: null, operation: null };
}

export function changeTaskEditDraft(
  state: TaskEditWorkflowState,
  draft: TaskEditDraft,
): TaskEditWorkflowState {
  if (
    state.draft.title === draft.title &&
    state.draft.description === draft.description &&
    state.draft.priority === draft.priority &&
    state.draft.due_on === draft.due_on
  ) {
    return state;
  }
  return {
    draft,
    status: "idle",
    error: null,
    operation: null,
  };
}

export function startTaskEditSave(
  state: TaskEditWorkflowState,
  operation: TaskEditOperation,
): TaskEditWorkflowState {
  return { ...state, status: "saving", error: null, operation };
}

export function failTaskEditSave(
  state: TaskEditWorkflowState,
  error: string,
): TaskEditWorkflowState {
  if (state.status !== "saving") return state;
  return { ...state, status: "error", error };
}

/** Expired operation receipts require a fresh authoritative read before retry. */
export function requireTaskEditReconciliation(
  state: TaskEditWorkflowState,
  error: string,
): TaskEditWorkflowState {
  if (state.status !== "saving") return state;
  return { ...state, status: "error", error, operation: null };
}

export function confirmTaskEditSave(
  draft: TaskEditDraft,
): TaskEditWorkflowState {
  return { draft, status: "saved", error: null, operation: null };
}

export function reviewTaskEditConflict(
  state: TaskEditWorkflowState,
): TaskEditWorkflowState {
  return { ...state, status: "conflict", error: null, operation: null };
}

export function retryTaskEditSave(
  state: TaskEditWorkflowState,
): { state: TaskEditWorkflowState; operation: TaskEditOperation } | null {
  if (state.status !== "error" || !state.operation) return null;
  return {
    state: { ...state, status: "saving", error: null },
    operation: state.operation,
  };
}
