import type { SupabaseClient } from "@supabase/supabase-js";

export interface DailyRepetitionPreview {
  status: "available" | "unavailable";
  board_id?: string;
  task_id?: string;
  current_task_id?: string;
  time_zone?: string;
  today?: string;
  existing_due_on?: string | null;
  existing_due_on_version?: number;
  proposed_start_on?: string;
  current?: { task_id: string; due_on: string; is_existing_task: true };
  future_dates?: string[];
  final_on?: string | null;
  occurrence_limit?: number | null;
  no_final_date?: boolean;
  remaining_dates_after_current?: number | null;
  start_in_past?: boolean;
  requires_start_confirmation?: boolean;
  previous_series_id?: string | null;
  previous_series_state?: "active" | "stopped" | "finished" | null;
  requires_previous_series_confirmation?: boolean;
}

export interface DailyRepetitionCreateCommand {
  operation_id: string;
  slug: string;
  task_id: string;
  start_on: string;
  end_on: string | null;
  occurrence_limit: number | null;
  expected_due_on_version: number;
  confirm_start_change: boolean;
  previous_series_id: string | null;
}

export interface DailyRepetitionCreateResult {
  status:
    | "confirmed"
    | "confirmation_required"
    | "conflict"
    | "unavailable"
    | "expired_unknown";
  operation_id?: string;
  series_id?: string;
  task_id?: string;
  due_on?: string | null;
  state?: "active" | "stopped" | "finished";
  next_due_on?: string | null;
  consumed_count?: number;
  occurrence_limit?: number | null;
  end_on?: string | null;
  confirmation?: "change_current_due_date" | "new_series_from_stopped";
  existing_due_on?: string | null;
  proposed_start_on?: string;
  previous_series_id?: string;
  previous_series_state?: "stopped" | "finished";
  reason?: string;
  task?: Record<string, unknown>;
}

export interface DailyRepetitionStatus {
  status: "available" | "not_repeating" | "unavailable";
  series_id?: string;
  state?: "active" | "stopped" | "finished";
  start_on?: string;
  end_on?: string | null;
  occurrence_limit?: number | null;
  consumed_count?: number;
  latest_occurrence_on?: string;
  next_due_on?: string | null;
  revision?: number;
  occurrences?: Array<{
    occurrence_on: string;
    task_id: string;
    state: "current" | "replaced" | "excluded" | "purged" | "transferred";
    due_on_override: string | null;
  }>;
  diagnostic?: {
    status: string;
    attempt_count: number;
    last_error_code: string | null;
    last_error_at: string | null;
  } | null;
}

export type DailyRepetitionErrorReason =
  | "uncertain"
  | "rejected"
  | "access_denied";

export class DailyRepetitionError extends Error {
  constructor(readonly reason: DailyRepetitionErrorReason) {
    super("No se pudo confirmar la repetición diaria.");
    this.name = "DailyRepetitionError";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function throwDailyRepetitionError(error: unknown): never {
  const code =
    isRecord(error) && typeof error.code === "string" ? error.code : "";
  if (code === "42501") throw new DailyRepetitionError("access_denied");
  if (code.startsWith("22") || code === "23514") {
    throw new DailyRepetitionError("rejected");
  }
  throw new DailyRepetitionError("uncertain");
}

export async function previewDailyRepetition(
  supabase: SupabaseClient,
  slug: string,
  taskId: string,
  startOn: string,
  endOn: string | null,
  occurrenceLimit: number | null,
): Promise<DailyRepetitionPreview> {
  const { data, error } = await supabase.rpc("preview_daily_repetition_p", {
    p_slug: slug,
    p_task_id: taskId,
    p_start_on: startOn,
    p_end_on: endOn,
    p_occurrence_limit: occurrenceLimit,
  });
  if (error) throwDailyRepetitionError(error);
  if (
    !isRecord(data) ||
    !["available", "unavailable"].includes(String(data.status))
  ) {
    throw new DailyRepetitionError("uncertain");
  }
  return data as unknown as DailyRepetitionPreview;
}

export async function createDailyRepetition(
  supabase: SupabaseClient,
  command: DailyRepetitionCreateCommand,
): Promise<DailyRepetitionCreateResult> {
  const { data, error } = await supabase.rpc("create_daily_repetition_p", {
    p_operation_id: command.operation_id,
    p_slug: command.slug,
    p_task_id: command.task_id,
    p_start_on: command.start_on,
    p_end_on: command.end_on,
    p_occurrence_limit: command.occurrence_limit,
    p_expected_due_on_version: command.expected_due_on_version,
    p_confirm_start_change: command.confirm_start_change,
    p_previous_series_id: command.previous_series_id,
  });
  if (error) throwDailyRepetitionError(error);
  if (!isRecord(data) || typeof data.status !== "string") {
    throw new DailyRepetitionError("uncertain");
  }
  return data as unknown as DailyRepetitionCreateResult;
}

export async function getDailyRepetition(
  supabase: SupabaseClient,
  slug: string,
  taskId: string,
): Promise<DailyRepetitionStatus> {
  const { data, error } = await supabase.rpc("get_daily_repetition_p", {
    p_slug: slug,
    p_task_id: taskId,
  });
  if (error) throwDailyRepetitionError(error);
  if (
    !isRecord(data) ||
    !["available", "not_repeating", "unavailable"].includes(String(data.status))
  ) {
    throw new DailyRepetitionError("uncertain");
  }
  return data as unknown as DailyRepetitionStatus;
}
