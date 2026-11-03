export interface RepetitionSeriesDeletionPreview {
  status: "available" | "unavailable";
  series_id?: string;
  state?: "active" | "stopped" | "finished";
  revision?: number;
  title?: string | null;
  occurrence_count?: number;
  task_count?: number;
  requires_confirmation?: boolean;
  retention_hours?: number;
}

export interface RepetitionSeriesDeletionCommand {
  operation_id: string;
  slug: string;
  series_id: string;
  expected_revision: number;
  confirm_history: true;
}

export interface DeletedRepetitionSeriesEligibility {
  series_id: string;
  deleted_at: string;
  expires_at: string;
  eligibility_checked_at: string;
  can_restore: boolean;
  generation_available: boolean;
  appearance_column_available: boolean;
  child_columns_available: boolean;
}

export interface RepetitionSeriesRestoreAction {
  status: "restore" | "needs_destination" | "expired" | "unavailable";
  targetColumnId: string | null;
}

export function createRepetitionSeriesDeletionCommand(
  preview: RepetitionSeriesDeletionPreview,
  input: {
    operationId: string;
    slug: string;
    seriesId: string;
    expectedRevision: number;
  },
): RepetitionSeriesDeletionCommand | null {
  if (
    preview.status !== "available" ||
    preview.series_id !== input.seriesId ||
    preview.revision !== input.expectedRevision ||
    preview.requires_confirmation !== true ||
    preview.retention_hours !== 168 ||
    !Number.isInteger(preview.occurrence_count) ||
    (preview.occurrence_count ?? -1) < 0 ||
    !Number.isInteger(preview.task_count) ||
    (preview.task_count ?? -1) < 0 ||
    !input.operationId ||
    !input.slug ||
    !input.seriesId ||
    !Number.isInteger(input.expectedRevision) ||
    input.expectedRevision < 1
  ) {
    return null;
  }
  return {
    operation_id: input.operationId,
    slug: input.slug,
    series_id: input.seriesId,
    expected_revision: input.expectedRevision,
    confirm_history: true,
  };
}

export function getRepetitionSeriesDeletionConfirmation(
  preview: RepetitionSeriesDeletionPreview,
) {
  const title = preview.title?.trim() || "Serie sin título";
  const occurrences = preview.occurrence_count ?? 0;
  const tasks = preview.task_count ?? 0;
  const taskLabel =
    tasks === 1 ? "tarjeta de la serie" : "tarjetas de la serie";
  const historyLabel = occurrences === 1 ? "ocurrencia" : "ocurrencias";
  return `Se eliminará toda la serie “${title}”: se cancelarán sus próximas apariciones y se quitarán del tablero ${tasks} ${taskLabel}. El historial de ${occurrences} ${historyLabel} quedará recuperable durante siete días. Las tarjetas eliminadas por separado conservan su propia recuperación y no volverán con la serie.`;
}

export function getRepetitionSeriesRestoreAction(
  item: DeletedRepetitionSeriesEligibility,
  currentColumnIds: string[],
  selectedDestinationId: string | null,
  eligibilityRequestStartedAtMonotonic: number,
  nowMonotonic: number,
): RepetitionSeriesRestoreAction {
  const checkedAt = Date.parse(item.eligibility_checked_at);
  const expiresAt = Date.parse(item.expires_at);
  if (
    !Number.isFinite(checkedAt) ||
    !Number.isFinite(expiresAt) ||
    !Number.isFinite(eligibilityRequestStartedAtMonotonic) ||
    !Number.isFinite(nowMonotonic)
  ) {
    return { status: "unavailable", targetColumnId: null };
  }
  const expiryMonotonic =
    eligibilityRequestStartedAtMonotonic + Math.max(0, expiresAt - checkedAt);
  if (nowMonotonic >= expiryMonotonic) {
    return { status: "expired", targetColumnId: null };
  }
  if (
    !item.can_restore ||
    !item.generation_available ||
    !item.child_columns_available
  ) {
    return { status: "unavailable", targetColumnId: null };
  }
  if (item.appearance_column_available) {
    return { status: "restore", targetColumnId: null };
  }
  if (
    selectedDestinationId &&
    currentColumnIds.includes(selectedDestinationId)
  ) {
    return { status: "restore", targetColumnId: selectedDestinationId };
  }
  return { status: "needs_destination", targetColumnId: null };
}
