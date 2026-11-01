export interface ColumnDeletionDestination {
  id: string;
  title: string;
  position: number;
}

export interface ColumnDeletionPreview {
  status: "preview";
  column_id: string;
  column_title: string;
  task_count: number;
  task_order_version: number;
  destinations: ColumnDeletionDestination[];
}

export type ColumnDeletionDecision =
  | "ready"
  | "needs_destination"
  | "invalid_destination"
  | "invalid_preview";

export interface ColumnDeletionCommand {
  operation_id: string;
  column_id: string;
  destination_column_id: string | null;
  expected_task_order_version: number;
}

export type ColumnDeletionDialogState =
  | { status: "closed" }
  | { status: "loading"; column_id: string; request_token?: number }
  | { status: "preview_error"; column_id: string }
  | {
      status: "ready";
      preview: ColumnDeletionPreview;
      destination_column_id: string | null;
    }
  | {
      status: "submitting";
      preview: ColumnDeletionPreview;
      command: ColumnDeletionCommand;
    }
  | {
      status: "submit_error";
      preview: ColumnDeletionPreview;
      command: ColumnDeletionCommand;
      error: Exclude<ColumnDeletionResultStatus, "confirmed">;
    };

export type ColumnDeletionResultStatus =
  | "confirmed"
  | "conflict"
  | "unavailable"
  | "needs_destination"
  | "expired"
  | "expired_unknown"
  | "retryable"
  | "uncertain";

export function startColumnDeletionPreview(
  columnId: string,
  requestToken?: number,
): ColumnDeletionDialogState {
  return {
    status: "loading",
    column_id: columnId,
    request_token: requestToken,
  };
}

export function resolveColumnDeletionPreview(
  state: ColumnDeletionDialogState,
  preview: ColumnDeletionPreview,
  requestToken?: number,
): ColumnDeletionDialogState {
  if (state.status !== "loading") return state;
  if (state.request_token !== requestToken) return state;
  if (state.column_id !== preview.column_id) {
    return { status: "preview_error", column_id: state.column_id };
  }
  return {
    status: "ready",
    preview,
    destination_column_id: null,
  };
}

export function failColumnDeletionPreview(
  state: ColumnDeletionDialogState,
  requestToken?: number,
): ColumnDeletionDialogState {
  return state.status === "loading" && state.request_token === requestToken
    ? { status: "preview_error", column_id: state.column_id }
    : state;
}

export function selectColumnDeletionDestination(
  state: ColumnDeletionDialogState,
  destinationColumnId: string | null,
): ColumnDeletionDialogState {
  if (state.status !== "ready") return state;
  if (
    destinationColumnId &&
    !state.preview.destinations.some(
      (destination) => destination.id === destinationColumnId,
    )
  ) {
    return state;
  }
  return { ...state, destination_column_id: destinationColumnId };
}

export function getColumnDeletionCommand(
  state: ColumnDeletionDialogState,
  operationId: string,
): ColumnDeletionCommand | null {
  if (state.status === "submit_error") return state.command;
  if (state.status !== "ready") return null;
  return createColumnDeletionCommand(
    state.preview,
    state.destination_column_id,
    operationId,
  );
}

export function startColumnDeletionSubmission(
  state: ColumnDeletionDialogState,
  operationId: string,
): { state: ColumnDeletionDialogState; command: ColumnDeletionCommand | null } {
  if (state.status === "submit_error") {
    return {
      state: { ...state, status: "submitting" },
      command: state.command,
    };
  }
  const command = getColumnDeletionCommand(state, operationId);
  if (!command || state.status !== "ready") return { state, command: null };
  return {
    state: { status: "submitting", preview: state.preview, command },
    command,
  };
}

export function failColumnDeletionSubmission(
  state: ColumnDeletionDialogState,
  error: Exclude<ColumnDeletionResultStatus, "confirmed">,
): ColumnDeletionDialogState {
  return state.status === "submitting"
    ? { ...state, status: "submit_error", error }
    : state;
}

export function closeColumnDeletionDialog(): ColumnDeletionDialogState {
  return { status: "closed" };
}

export function columnDeletionDecision(
  preview: ColumnDeletionPreview | null,
  destinationColumnId: string | null,
): ColumnDeletionDecision {
  if (
    !preview ||
    preview.status !== "preview" ||
    !Number.isInteger(preview.task_count) ||
    preview.task_count < 0 ||
    !Number.isInteger(preview.task_order_version) ||
    preview.task_order_version < 1
  ) {
    return "invalid_preview";
  }
  if (preview.task_count > 0 && !destinationColumnId) {
    return "needs_destination";
  }
  if (
    destinationColumnId &&
    !preview.destinations.some(
      (destination) => destination.id === destinationColumnId,
    )
  ) {
    return "invalid_destination";
  }
  return "ready";
}

export function createColumnDeletionCommand(
  preview: ColumnDeletionPreview,
  destinationColumnId: string | null,
  operationId: string,
): ColumnDeletionCommand | null {
  if (columnDeletionDecision(preview, destinationColumnId) !== "ready") {
    return null;
  }
  return {
    operation_id: operationId,
    column_id: preview.column_id,
    destination_column_id: destinationColumnId,
    expected_task_order_version: preview.task_order_version,
  };
}

export function columnDeletionErrorMessage(
  status: ColumnDeletionResultStatus,
): string {
  switch (status) {
    case "needs_destination":
      return "Elige una columna de este tablero para trasladar las tareas.";
    case "conflict":
      return "La columna o sus tareas cambiaron. Revisa la vista previa actualizada antes de confirmar.";
    case "unavailable":
      return "La columna ya no está disponible. Actualizamos el tablero.";
    case "expired":
      return "El plazo de recuperación venció. No se pudo recuperar la columna.";
    case "expired_unknown":
      return "No se pudo confirmar la operación anterior. Revisa la recuperación antes de intentarlo de nuevo.";
    case "retryable":
    case "uncertain":
      return "No se pudo confirmar el cambio. Revisa el tablero antes de volver a intentar.";
    case "confirmed":
      return "La columna se eliminó correctamente.";
  }
}
