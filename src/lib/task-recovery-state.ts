export interface TaskRecoveryLocation {
  can_restore: boolean;
  original_column_id: string;
}

export type TaskRecoveryListViewState = "loading" | "error" | "empty" | "ready";

export function getTaskRecoveryListViewState(input: {
  isLoading: boolean;
  hasError: boolean;
  itemCount: number;
  hasCurrentEligibility: boolean;
}): TaskRecoveryListViewState {
  if (!input.hasCurrentEligibility) {
    if (input.isLoading) return "loading";
    if (input.hasError) return "error";
    return "loading";
  }
  if (input.itemCount > 0) return "ready";
  if (input.isLoading) return "loading";
  if (input.hasError) return "error";
  return "empty";
}

export function taskRecoveryLoadErrorMessage(reason: string | null): string {
  return reason === "access_denied"
    ? "Ya no tienes permiso para ver la recuperación de este tablero."
    : "No se pudo cargar la recuperación. Actualiza la lista para volver a intentarlo.";
}

export function taskRecoveryRestoreErrorMessage(reason: string | null): string {
  if (reason === "access_denied") {
    return "Ya no tienes permiso para recuperar tareas de este tablero.";
  }
  if (reason === "uncertain") {
    return "No se pudo confirmar si la tarea se recuperó. Actualiza el tablero y la lista antes de volver a intentarlo.";
  }
  if (reason === "expired") {
    return "El plazo de recuperación venció. Esta tarea ya no se puede recuperar.";
  }
  return "No se pudo recuperar la tarea. Actualiza la lista y revisa el destino.";
}

export function shouldClearTaskRecoveryItems(reason: string | null): boolean {
  return reason === "access_denied";
}

export type TaskRecoveryAvailabilityReason =
  | "expired"
  | "needs_destination"
  | null;

export interface TaskRecoveryRestoreAction {
  canRestore: boolean;
  destinationColumnId: string | null;
  needsDestination: boolean;
  reason: TaskRecoveryAvailabilityReason;
}

export function getTaskRecoveryRestoreAction(
  item: TaskRecoveryLocation,
  activeColumnIds: readonly string[],
  selectedDestinationId: string | null,
): TaskRecoveryRestoreAction {
  if (!item.can_restore) {
    return {
      canRestore: false,
      destinationColumnId: null,
      needsDestination: false,
      reason: "expired",
    };
  }

  if (activeColumnIds.includes(item.original_column_id)) {
    return {
      canRestore: true,
      destinationColumnId: item.original_column_id,
      needsDestination: false,
      reason: null,
    };
  }

  if (
    !selectedDestinationId ||
    !activeColumnIds.includes(selectedDestinationId)
  ) {
    return {
      canRestore: false,
      destinationColumnId: null,
      needsDestination: true,
      reason: "needs_destination",
    };
  }

  return {
    canRestore: true,
    destinationColumnId: selectedDestinationId,
    needsDestination: false,
    reason: null,
  };
}

export function isTaskRecoveryRestorableAtMonotonicTime(
  item: {
    can_restore: boolean;
    expires_at: string;
    eligibility_checked_at: string;
  },
  eligibilityReceivedAtMonotonic: number,
  currentMonotonicTime: number,
  hasCurrentEligibility: boolean,
): boolean {
  if (
    !item.can_restore ||
    !hasCurrentEligibility ||
    !Number.isFinite(eligibilityReceivedAtMonotonic) ||
    !Number.isFinite(currentMonotonicTime)
  ) {
    return false;
  }

  const expiresAt = Date.parse(item.expires_at);
  const checkedAt = Date.parse(item.eligibility_checked_at);
  if (!Number.isFinite(expiresAt) || !Number.isFinite(checkedAt)) return false;

  const elapsedSinceResponse = Math.max(
    0,
    currentMonotonicTime - eligibilityReceivedAtMonotonic,
  );
  return expiresAt - checkedAt > elapsedSinceResponse;
}

export function taskRecoveryDestinationFieldIds(taskId: string): {
  labelId: string;
  selectId: string;
  htmlFor: string;
} {
  const selectId = `task-recovery-destination-${taskId}`;
  return {
    labelId: `task-recovery-destination-label-${taskId}`,
    selectId,
    htmlFor: selectId,
  };
}

export function formatTaskRecoveryTimestamp(
  value: string,
  timeZone: string,
): string {
  const date = new Date(value);
  if (!Number.isFinite(date.valueOf())) return "Fecha no disponible";
  try {
    return new Intl.DateTimeFormat("es-AR", {
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      hourCycle: "h23",
      minute: "2-digit",
      second: "2-digit",
      timeZone,
      timeZoneName: "shortOffset",
    }).format(date);
  } catch {
    return "Fecha no disponible";
  }
}

export function taskRecoveryCauseLabel(cause: string): string {
  return cause === "user_requested"
    ? "Eliminada manualmente"
    : "Motivo de eliminación no disponible";
}
