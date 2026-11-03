import type { SupabaseClient } from "@supabase/supabase-js";
import type { BoardLabel, BoardLabelColor } from "@/lib/types";

export interface DeletedBoardLabel extends BoardLabel {
  deleted_at: string;
  expires_at: string;
}

export interface BoardLabelTaskAssignment {
  task_id: string;
  labels: BoardLabel[];
}

export interface BoardLabelBirthdayAssignment {
  birthday_id: string;
  labels: BoardLabel[];
}

export interface BoardLabelAssignmentsResult {
  status: "available" | "unavailable";
  tasks: BoardLabelTaskAssignment[];
  birthdays: BoardLabelBirthdayAssignment[];
}

export interface BoardLabelItemPreview {
  id: string;
  title?: string;
  name?: string;
  active_label_count: number;
  would_exceed_limit: boolean;
}

export interface BoardLabelSeriesPreview extends BoardLabelItemPreview {
  state: "active" | "stopped" | "finished";
}

export interface BoardLabelRestorePreview {
  status: "preview" | "unavailable" | "expired";
  can_restore?: boolean;
  reasons?: string[];
  label?: DeletedBoardLabel & { proposed_name: string };
  associated_tasks: BoardLabelItemPreview[];
  associated_birthdays: BoardLabelItemPreview[];
  associated_series: BoardLabelSeriesPreview[];
}

export interface BoardLabelMutationResult {
  status: "confirmed" | "conflict" | "unavailable" | "expired";
  reason?: string;
  label?: BoardLabel;
  labels?: BoardLabel[];
}

export class BoardLabelsUnavailableError extends Error {
  constructor() {
    super("El catálogo de etiquetas no está disponible con el acceso actual.");
    this.name = "BoardLabelsUnavailableError";
  }
}

export class BoardLabelTrashUnavailableError extends Error {
  constructor() {
    super("La papelera de etiquetas no está disponible con el acceso actual.");
    this.name = "BoardLabelTrashUnavailableError";
  }
}

const palette: readonly BoardLabelColor[] = [
  "red",
  "orange",
  "yellow",
  "green",
  "teal",
  "blue",
  "purple",
  "pink",
  "gray",
];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isLabel(value: unknown): value is BoardLabel {
  return (
    isRecord(value) &&
    typeof value.id === "string" &&
    typeof value.board_id === "string" &&
    typeof value.name === "string" &&
    typeof value.color === "string" &&
    palette.includes(value.color as BoardLabelColor) &&
    typeof value.version === "number"
  );
}

function isDeletedLabel(value: unknown): value is DeletedBoardLabel {
  return (
    isLabel(value) &&
    isRecord(value) &&
    typeof value.deleted_at === "string" &&
    typeof value.expires_at === "string"
  );
}

async function call<T extends { status: string }>(
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

export async function listBoardLabels(
  supabase: SupabaseClient,
  slug: string,
): Promise<BoardLabel[]> {
  const result = await call<{
    status: string;
    labels?: unknown;
  }>(supabase, "list_board_labels_p", { p_slug: slug });
  if (result.status === "unavailable") {
    throw new BoardLabelsUnavailableError();
  }
  if (
    result.status !== "available" ||
    !Array.isArray(result.labels) ||
    !result.labels.every(isLabel)
  ) {
    throw new Error("No se pudo consultar el catálogo de etiquetas.");
  }
  return result.labels;
}

export async function listDeletedBoardLabels(
  supabase: SupabaseClient,
  slug: string,
): Promise<DeletedBoardLabel[]> {
  const result = await call<{
    status: string;
    labels?: unknown;
  }>(supabase, "list_deleted_board_labels_p", { p_slug: slug });
  if (result.status === "unavailable") {
    throw new BoardLabelTrashUnavailableError();
  }
  if (
    result.status !== "available" ||
    !Array.isArray(result.labels) ||
    !result.labels.every(isDeletedLabel)
  ) {
    throw new Error("No se pudo consultar la papelera de etiquetas.");
  }
  return result.labels;
}

export async function getBoardLabelAssignments(
  supabase: SupabaseClient,
  slug: string,
): Promise<BoardLabelAssignmentsResult> {
  const result = await call<{
    status: string;
    tasks?: unknown;
    birthdays?: unknown;
  }>(supabase, "get_board_label_assignments_p", { p_slug: slug });
  if (
    result.status !== "available" ||
    !Array.isArray(result.tasks) ||
    !Array.isArray(result.birthdays)
  ) {
    if (result.status === "unavailable") {
      return { status: "unavailable", tasks: [], birthdays: [] };
    }
    throw new Error("No se pudieron consultar las etiquetas de este tablero.");
  }
  const tasks = result.tasks.filter(
    (entry): entry is BoardLabelTaskAssignment =>
      isRecord(entry) &&
      typeof entry.task_id === "string" &&
      Array.isArray(entry.labels) &&
      entry.labels.every(isLabel),
  );
  const birthdays = result.birthdays.filter(
    (entry): entry is BoardLabelBirthdayAssignment =>
      isRecord(entry) &&
      typeof entry.birthday_id === "string" &&
      Array.isArray(entry.labels) &&
      entry.labels.every(isLabel),
  );
  if (
    tasks.length !== result.tasks.length ||
    birthdays.length !== result.birthdays.length
  ) {
    throw new Error("La respuesta de etiquetas del tablero está incompleta.");
  }
  return { status: "available", tasks, birthdays };
}

export function createBoardLabel(
  supabase: SupabaseClient,
  command: { slug: string; name: string; color: BoardLabelColor },
) {
  return call<BoardLabelMutationResult>(supabase, "create_board_label_p", {
    p_slug: command.slug,
    p_name: command.name,
    p_color: command.color,
  });
}

export function updateBoardLabel(
  supabase: SupabaseClient,
  command: {
    slug: string;
    labelId: string;
    expectedVersion: number;
    name: string;
    color: BoardLabelColor;
  },
) {
  return call<BoardLabelMutationResult>(supabase, "update_board_label_p", {
    p_slug: command.slug,
    p_label_id: command.labelId,
    p_expected_version: command.expectedVersion,
    p_name: command.name,
    p_color: command.color,
  });
}

export function deleteBoardLabel(
  supabase: SupabaseClient,
  command: { slug: string; labelId: string; expectedVersion: number },
) {
  return call<BoardLabelMutationResult>(supabase, "delete_board_label_p", {
    p_slug: command.slug,
    p_label_id: command.labelId,
    p_expected_version: command.expectedVersion,
  });
}

export function previewRestoreBoardLabel(
  supabase: SupabaseClient,
  command: { slug: string; labelId: string; name: string },
) {
  return call<BoardLabelRestorePreview>(
    supabase,
    "preview_restore_board_label_with_series_p",
    {
      p_slug: command.slug,
      p_label_id: command.labelId,
      p_name: command.name,
    },
  );
}

export function restoreBoardLabel(
  supabase: SupabaseClient,
  command: {
    slug: string;
    labelId: string;
    expectedVersion: number;
    name: string;
    taskIds: string[];
    birthdayIds: string[];
    seriesIds: string[];
  },
) {
  return call<
    BoardLabelMutationResult & {
      restored_series_ids?: string[];
      omitted_series_ids?: string[];
    }
  >(supabase, "restore_board_label_with_series_p", {
    p_slug: command.slug,
    p_label_id: command.labelId,
    p_expected_version: command.expectedVersion,
    p_name: command.name,
    p_task_ids: command.taskIds,
    p_birthday_ids: command.birthdayIds,
    p_series_ids: command.seriesIds,
  });
}

export function getTaskLabels(
  supabase: SupabaseClient,
  slug: string,
  taskId: string,
) {
  return call<{ status: string; labels?: unknown }>(
    supabase,
    "get_task_labels_p",
    { p_slug: slug, p_task_id: taskId },
  );
}

export async function setTaskLabels(
  supabase: SupabaseClient,
  slug: string,
  taskId: string,
  expectedLabelIds: string[],
  labelIds: string[],
) {
  const result = await call<BoardLabelMutationResult & { task_id?: string }>(
    supabase,
    "set_task_labels_p",
    {
      p_slug: slug,
      p_task_id: taskId,
      p_expected_label_ids: expectedLabelIds,
      p_label_ids: labelIds,
    },
  );
  if (
    result.reason === "stale_selection" &&
    (!Array.isArray(result.labels) || !result.labels.every(isLabel))
  ) {
    throw new Error("La respuesta de conflicto de etiquetas está incompleta.");
  }
  return result;
}

export function getBirthdayLabels(
  supabase: SupabaseClient,
  slug: string,
  birthdayId: string,
) {
  return call<{ status: string; labels?: unknown }>(
    supabase,
    "get_birthday_labels_p",
    { p_slug: slug, p_birthday_id: birthdayId },
  );
}

export async function setBirthdayLabels(
  supabase: SupabaseClient,
  slug: string,
  birthdayId: string,
  expectedLabelIds: string[],
  labelIds: string[],
) {
  const result = await call<
    BoardLabelMutationResult & { birthday_id?: string }
  >(supabase, "set_birthday_labels_p", {
    p_slug: slug,
    p_birthday_id: birthdayId,
    p_expected_label_ids: expectedLabelIds,
    p_label_ids: labelIds,
  });
  if (
    result.reason === "stale_selection" &&
    (!Array.isArray(result.labels) || !result.labels.every(isLabel))
  ) {
    throw new Error("La respuesta de conflicto de etiquetas está incompleta.");
  }
  return result;
}
