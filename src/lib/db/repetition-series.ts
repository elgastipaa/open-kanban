import type { SupabaseClient } from "@supabase/supabase-js";
import type { RepetitionPattern } from "@/lib/db/daily-repetition";
import type { Priority, Task } from "@/lib/types";

export interface RepetitionSeriesListItem {
  id: string;
  board_id: string;
  board_slug: string;
  board_name: string;
  board_time_zone: string;
  state: "active" | "stopped" | "finished";
  rule: "daily" | "weekly" | "monthly" | "yearly";
  pattern: RepetitionPattern;
  start_on: string;
  end_on: string | null;
  occurrence_limit: number | null;
  consumed_count: number;
  latest_occurrence_on: string;
  next_due_on: string | null;
  next_appearance_on?: string | null;
  revision: number;
  advance_days: number;
  appearance_column_id: string;
  current_task_id: string | null;
  current_task_title?: string | null;
  created_at: string;
}

export interface RepetitionSeriesPage {
  status: "available" | "unavailable";
  series: RepetitionSeriesListItem[];
  has_more: boolean;
  next_cursor?: { created_at: string; id: string } | null;
}

export interface RepetitionHistoryOccurrence {
  id: string;
  occurrence_on: string;
  task_id: string | null;
  state:
    | "current"
    | "replaced"
    | "excluded"
    | "purged"
    | "transferred"
    | "retired";
  due_on_override: string | null;
  title?: string;
  description?: string | null;
  priority?: Priority;
  is_completed?: boolean;
  due_on?: string | null;
  created_by?: string | null;
  comment_count?: number;
  latest_comment_id?: string;
  content_available: boolean;
}

export interface RepetitionHistoryPage {
  status: "available" | "unavailable";
  series?: {
    id: string;
    board_id: string;
    board_slug: string;
    board_name: string;
    board_time_zone: string;
    state: "active" | "stopped" | "finished";
    rule: "daily" | "weekly" | "monthly" | "yearly";
    pattern: Record<string, unknown>;
    start_on: string;
    end_on: string | null;
    occurrence_limit: number | null;
    consumed_count: number;
    latest_occurrence_on: string;
    next_due_on: string | null;
    revision: number;
    advance_days: number;
    appearance_column_id: string;
  };
  occurrences: RepetitionHistoryOccurrence[];
  has_more: boolean;
  next_cursor?: { occurrence_on: string; id: string } | null;
}

export interface RepetitionOccurrenceDetail {
  status: "available" | "unavailable";
  board_slug?: string;
  series?: {
    id: string;
    board_id: string;
    board_slug: string;
    board_name: string;
    state: "active" | "stopped" | "finished";
    revision: number;
  };
  occurrence?: RepetitionHistoryOccurrence & {
    task?: {
      id: string;
      title: string;
      description: string | null;
      priority: Priority;
      is_completed: boolean;
      due_on: string | null;
      created_by: string | null;
      comment_count: number;
      latest_comment_id?: string;
    };
  };
}

export interface HistoricalTaskCopyPreview {
  status: "available" | "unavailable" | "source_changed";
  board_id?: string;
  source_task_id?: string;
  source_column_id?: string;
  target_column_id?: string;
  title?: string;
  description?: string | null;
  priority?: Priority;
  steps?: Array<{ text: string; position: number; is_completed: false }>;
  step_count?: number;
  source_hash?: string;
}

export interface HistoricalTaskCopyResult {
  status: "confirmed" | "source_changed" | "unavailable" | "expired_unknown";
  operation_id?: string;
  task_id?: string;
  task?: Task;
  title?: string;
  target_column_id?: string;
  source_task_id?: string;
  description?: string | null;
  priority?: Priority;
  steps?: Array<{ text: string; position: number; is_completed: false }>;
  source_hash?: string;
}

export interface StopRepetitionResult {
  status:
    | "confirmed"
    | "conflict"
    | "unavailable"
    | "already_stopped"
    | "finished"
    | "expired_unknown";
  operation_id?: string;
  series_id?: string;
  series_revision?: number;
  state?: "active" | "stopped" | "finished";
  next_due_on?: string | null;
  current_occurrence_id?: string | null;
  current_task_id?: string | null;
  consumed_count?: number;
}

export interface RepetitionSeriesDeletionPreview {
  status: "available" | "unavailable";
  series_id?: string;
  board_id?: string;
  board_slug?: string;
  state?: "active" | "stopped" | "finished";
  revision?: number;
  occurrence_count?: number;
  task_count?: number;
  title?: string | null;
  requires_confirmation?: boolean;
  retention_hours?: number;
}

export interface RepetitionSeriesDeletionResult {
  status:
    | "confirmed"
    | "conflict"
    | "unavailable"
    | "confirmation_required"
    | "expired_unknown";
  operation_id?: string;
  series_id?: string;
  state?: "active" | "stopped" | "finished";
  deleted_at?: string;
  expires_at?: string;
  occurrence_count?: number;
  task_count?: number;
}

export interface DeletedRepetitionSeriesItem {
  series_id: string;
  board_id: string;
  board_slug: string;
  board_name: string;
  title: string | null;
  state: "active" | "stopped" | "finished";
  deleted_at: string;
  expires_at: string;
  occurrence_count: number;
  can_restore: boolean;
  generation_available: boolean;
  appearance_column_available: boolean;
  child_columns_available: boolean;
  eligibility_checked_at: string;
}

export interface DeletedRepetitionSeriesPage {
  status: "available" | "unavailable";
  series: DeletedRepetitionSeriesItem[];
}

export interface RepetitionSeriesRestoreResult {
  status:
    | "confirmed"
    | "expired"
    | "unavailable"
    | "needs_parent"
    | "needs_destination"
    | "expired_unknown";
  operation_id?: string;
  series_id?: string;
  state?: "active" | "stopped" | "finished";
  series_revision?: number;
  next_due_on?: string | null;
  appearance_column_id?: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function callRpc<T>(
  supabase: SupabaseClient,
  name: string,
  args: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  if (!isRecord(data) || typeof data.status !== "string") {
    throw new Error(`Respuesta inválida de ${name}`);
  }
  return data as T;
}

export function listRepetitionSeries(
  supabase: SupabaseClient,
  boardId: string | null,
  state: RepetitionSeriesListItem["state"] | null,
  cursor: { created_at: string; id: string } | null,
  limit = 20,
) {
  return callRpc<RepetitionSeriesPage>(supabase, "list_repetition_series_p", {
    p_board_id: boardId,
    p_before_created_at: cursor?.created_at ?? null,
    p_before_id: cursor?.id ?? null,
    p_limit: limit,
    p_state: state,
  });
}

export function getRepetitionHistoryPage(
  supabase: SupabaseClient,
  seriesId: string,
  cursor: { occurrence_on: string; id: string } | null,
  limit = 30,
) {
  return callRpc<RepetitionHistoryPage>(
    supabase,
    "get_repetition_history_page_p",
    {
      p_series_id: seriesId,
      p_before_on: cursor?.occurrence_on ?? null,
      p_before_id: cursor?.id ?? null,
      p_limit: limit,
    },
  );
}

export function getRepetitionHistoryOccurrence(
  supabase: SupabaseClient,
  seriesId: string,
  occurrenceId: string,
) {
  return callRpc<RepetitionOccurrenceDetail>(
    supabase,
    "get_repetition_history_occurrence_p",
    { p_series_id: seriesId, p_occurrence_id: occurrenceId },
  );
}

export function previewHistoricalTaskCopy(
  supabase: SupabaseClient,
  slug: string,
  taskId: string,
) {
  return callRpc<HistoricalTaskCopyPreview>(
    supabase,
    "preview_historical_task_copy_p",
    { p_slug: slug, p_task_id: taskId },
  );
}

export function copyHistoricalTask(
  supabase: SupabaseClient,
  command: {
    operationId: string;
    slug: string;
    sourceTaskId: string;
    targetColumnId: string;
    title: string;
    expectedSourceHash: string;
  },
) {
  return callRpc<HistoricalTaskCopyResult>(supabase, "copy_historical_task_p", {
    p_operation_id: command.operationId,
    p_slug: command.slug,
    p_source_task_id: command.sourceTaskId,
    p_target_column_id: command.targetColumnId,
    p_title: command.title,
    p_expected_source_hash: command.expectedSourceHash,
  });
}

export function stopRepetitionSeries(
  supabase: SupabaseClient,
  command: {
    operationId: string;
    slug: string;
    seriesId: string;
    expectedRevision: number;
  },
) {
  return callRpc<StopRepetitionResult>(supabase, "stop_repetition_series_p", {
    p_operation_id: command.operationId,
    p_slug: command.slug,
    p_series_id: command.seriesId,
    p_expected_revision: command.expectedRevision,
  });
}

export function previewDeleteRepetitionSeries(
  supabase: SupabaseClient,
  slug: string,
  seriesId: string,
) {
  return callRpc<RepetitionSeriesDeletionPreview>(
    supabase,
    "preview_delete_repetition_series_p",
    { p_slug: slug, p_series_id: seriesId },
  );
}

export function deleteRepetitionSeries(
  supabase: SupabaseClient,
  command: {
    operationId: string;
    slug: string;
    seriesId: string;
    expectedRevision: number;
    confirmHistory: boolean;
  },
) {
  return callRpc<RepetitionSeriesDeletionResult>(
    supabase,
    "delete_repetition_series_p",
    {
      p_operation_id: command.operationId,
      p_slug: command.slug,
      p_series_id: command.seriesId,
      p_expected_revision: command.expectedRevision,
      p_confirm_history: command.confirmHistory,
    },
  );
}

export function listDeletedRepetitionSeries(
  supabase: SupabaseClient,
  boardId: string,
) {
  return callRpc<DeletedRepetitionSeriesPage>(
    supabase,
    "list_deleted_repetition_series_p",
    { p_board_id: boardId },
  );
}

export function restoreRepetitionSeries(
  supabase: SupabaseClient,
  command: {
    operationId: string;
    slug: string;
    seriesId: string;
    targetAppearanceColumnId: string | null;
  },
) {
  return callRpc<RepetitionSeriesRestoreResult>(
    supabase,
    "restore_repetition_series_p",
    {
      p_operation_id: command.operationId,
      p_slug: command.slug,
      p_series_id: command.seriesId,
      p_target_appearance_column_id: command.targetAppearanceColumnId,
    },
  );
}
