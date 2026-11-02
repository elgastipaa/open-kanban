import type { SupabaseClient } from "@supabase/supabase-js";

export type RepetitionPattern =
  | { frequency: "daily"; interval: number }
  | { frequency: "weekly"; interval: number; weekdays: number[] }
  | {
      frequency: "monthly";
      interval: number | string;
      day_of_month: number;
    }
  | {
      frequency: "monthly";
      interval: number | string;
      ordinal: number;
      weekday: number;
    }
  | {
      frequency: "yearly";
      interval: number | string;
      month: number;
      day_of_month: number;
    }
  | {
      frequency: "yearly";
      interval: number | string;
      month: number;
      ordinal: number;
      weekday: number;
    };

export interface RepetitionPreview {
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
  appearance_dates?: string[];
  advance_days?: number;
  minimum_separation_days?: number;
  final_on?: string | null;
  occurrence_limit?: number | null;
  pattern?: RepetitionPattern;
  no_final_date?: boolean;
  remaining_dates_after_current?: number | null;
  start_in_past?: boolean;
  requires_start_confirmation?: boolean;
  previous_series_id?: string | null;
  previous_series_state?: "active" | "stopped" | "finished" | null;
  requires_previous_series_confirmation?: boolean;
}

export interface RepetitionCreateCommand {
  operation_id: string;
  slug: string;
  task_id: string;
  start_on: string;
  end_on: string | null;
  occurrence_limit: number | null;
  pattern: RepetitionPattern;
  advance_days: number;
  appearance_column_id: string;
  expected_due_on_version: number;
  confirm_start_change: boolean;
  previous_series_id: string | null;
}

export interface RepetitionCreateResult {
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
  advance_days?: number;
  appearance_on?: string | null;
  minimum_separation_days?: number;
  confirmation?: "change_current_due_date" | "new_series_from_stopped";
  existing_due_on?: string | null;
  proposed_start_on?: string;
  previous_series_id?: string;
  previous_series_state?: "stopped" | "finished";
  reason?: string;
  task?: Record<string, unknown>;
}

export interface RepetitionStatus {
  status: "available" | "not_repeating" | "unavailable";
  series_id?: string;
  state?: "active" | "stopped" | "finished";
  start_on?: string;
  end_on?: string | null;
  occurrence_limit?: number | null;
  rule?: "daily" | "weekly" | "monthly" | "yearly";
  pattern?: RepetitionPattern;
  consumed_count?: number;
  latest_occurrence_on?: string;
  next_due_on?: string | null;
  revision?: number;
  advance_days?: number;
  appearance_column_id?: string;
  template_snapshot?: RepetitionSeriesTemplate;
  occurrences?: Array<{
    occurrence_on: string;
    task_id: string;
    state:
      | "current"
      | "replaced"
      | "excluded"
      | "purged"
      | "transferred"
      | "retired";
    due_on_override: string | null;
  }>;
  diagnostic?: {
    status: string;
    attempt_count: number;
    last_error_code: string | null;
    last_error_at: string | null;
  } | null;
}

export interface RepetitionSeriesTemplate {
  title: string;
  description: string | null;
  priority: "low" | "medium" | "high" | "urgent";
  assignee_id: string | null;
  steps?: Array<Record<string, unknown>>;
}

export type RepetitionFinalMode = "count" | "date" | "none";

export interface RepetitionEditPreview {
  status: "available" | "unavailable";
  requires_date_choice?: boolean;
  selected_date_compatible?: boolean;
  reason?: string;
  series_id?: string;
  series_revision?: number;
  current_task_id?: string;
  current_due_on?: string | null;
  current_column_id?: string;
  time_zone?: string;
  today?: string;
  proposed_start_on?: string;
  selected_start_on?: string;
  start_on?: string;
  final_mode?: RepetitionFinalMode;
  future_count?: number | null;
  end_on?: string | null;
  final_on?: string | null;
  future_dates?: string[];
  appearance_dates?: string[];
  advance_days?: number;
  minimum_separation_days?: number;
  pattern?: RepetitionPattern;
  appearance_column_id?: string;
  template_snapshot?: RepetitionSeriesTemplate;
  preserved_exclusion_dates?: string[];
  removed_exclusion_dates?: string[];
}

export interface RepetitionEditCommand {
  operation_id: string;
  slug: string;
  task_id: string;
  expected_revision: number;
  start_on: string;
  final_mode: RepetitionFinalMode;
  future_count: number | null;
  end_on: string | null;
  pattern: RepetitionPattern;
  advance_days: number;
  appearance_column_id: string;
  template: RepetitionSeriesTemplate;
  confirm_date_choice: boolean;
}

export type RepetitionEditResult = Omit<RepetitionEditPreview, "status"> & {
  status:
    | "confirmed"
    | "date_choice_required"
    | "conflict"
    | "unavailable"
    | "expired_unknown";
  operation_id?: string;
  next_due_on?: string | null;
  occurrence_limit?: number | null;
};

export type RepetitionErrorReason = "uncertain" | "rejected" | "access_denied";

export class RepetitionError extends Error {
  constructor(readonly reason: RepetitionErrorReason) {
    super("No se pudo confirmar la repetición.");
    this.name = "RepetitionError";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function throwRepetitionError(error: unknown): never {
  const code =
    isRecord(error) && typeof error.code === "string" ? error.code : "";
  if (code === "42501") throw new RepetitionError("access_denied");
  if (code.startsWith("22") || code === "23514") {
    throw new RepetitionError("rejected");
  }
  throw new RepetitionError("uncertain");
}

export async function previewRepetition(
  supabase: SupabaseClient,
  slug: string,
  taskId: string,
  startOn: string,
  endOn: string | null,
  occurrenceLimit: number | null,
  pattern: RepetitionPattern,
  advanceDays: number,
): Promise<RepetitionPreview> {
  const { data, error } = await supabase.rpc(
    "preview_repetition_with_advance_p",
    {
      p_slug: slug,
      p_task_id: taskId,
      p_start_on: startOn,
      p_end_on: endOn,
      p_occurrence_limit: occurrenceLimit,
      p_pattern: pattern,
      p_advance_days: advanceDays,
    },
  );
  if (error) throwRepetitionError(error);
  if (
    !isRecord(data) ||
    !["available", "unavailable"].includes(String(data.status))
  ) {
    throw new RepetitionError("uncertain");
  }
  return data as unknown as RepetitionPreview;
}

export async function createRepetition(
  supabase: SupabaseClient,
  command: RepetitionCreateCommand,
): Promise<RepetitionCreateResult> {
  const { data, error } = await supabase.rpc(
    "create_repetition_with_advance_p",
    {
      p_operation_id: command.operation_id,
      p_slug: command.slug,
      p_task_id: command.task_id,
      p_start_on: command.start_on,
      p_end_on: command.end_on,
      p_occurrence_limit: command.occurrence_limit,
      p_pattern: command.pattern,
      p_advance_days: command.advance_days,
      p_appearance_column_id: command.appearance_column_id,
      p_expected_due_on_version: command.expected_due_on_version,
      p_confirm_start_change: command.confirm_start_change,
      p_previous_series_id: command.previous_series_id,
    },
  );
  if (error) throwRepetitionError(error);
  if (!isRecord(data) || typeof data.status !== "string") {
    throw new RepetitionError("uncertain");
  }
  return data as unknown as RepetitionCreateResult;
}

export async function previewRepetitionEdit(
  supabase: SupabaseClient,
  command: Omit<RepetitionEditCommand, "operation_id" | "expected_revision">,
): Promise<RepetitionEditPreview> {
  const { data, error } = await supabase.rpc("preview_repetition_edit_p", {
    p_slug: command.slug,
    p_task_id: command.task_id,
    p_start_on: command.start_on,
    p_final_mode: command.final_mode,
    p_future_count: command.future_count,
    p_end_on: command.end_on,
    p_pattern: command.pattern,
    p_advance_days: command.advance_days,
    p_appearance_column_id: command.appearance_column_id,
    p_template: command.template,
    p_confirm_date_choice: command.confirm_date_choice,
  });
  if (error) throwRepetitionError(error);
  if (
    !isRecord(data) ||
    !["available", "unavailable"].includes(String(data.status))
  ) {
    throw new RepetitionError("uncertain");
  }
  return data as unknown as RepetitionEditPreview;
}

export async function editRepetition(
  supabase: SupabaseClient,
  command: RepetitionEditCommand,
): Promise<RepetitionEditResult> {
  const { data, error } = await supabase.rpc("edit_repetition_p", {
    p_operation_id: command.operation_id,
    p_slug: command.slug,
    p_task_id: command.task_id,
    p_expected_revision: command.expected_revision,
    p_start_on: command.start_on,
    p_final_mode: command.final_mode,
    p_future_count: command.future_count,
    p_end_on: command.end_on,
    p_pattern: command.pattern,
    p_advance_days: command.advance_days,
    p_appearance_column_id: command.appearance_column_id,
    p_template: command.template,
    p_confirm_date_choice: command.confirm_date_choice,
  });
  if (error) throwRepetitionError(error);
  if (
    !isRecord(data) ||
    ![
      "confirmed",
      "date_choice_required",
      "conflict",
      "unavailable",
      "expired_unknown",
    ].includes(String(data.status))
  ) {
    throw new RepetitionError("uncertain");
  }
  return data as unknown as RepetitionEditResult;
}

export async function getRepetition(
  supabase: SupabaseClient,
  slug: string,
  taskId: string,
): Promise<RepetitionStatus> {
  const { data, error } = await supabase.rpc("get_repetition_p", {
    p_slug: slug,
    p_task_id: taskId,
  });
  if (error) throwRepetitionError(error);
  if (
    !isRecord(data) ||
    !["available", "not_repeating", "unavailable"].includes(String(data.status))
  ) {
    throw new RepetitionError("uncertain");
  }
  return data as unknown as RepetitionStatus;
}
