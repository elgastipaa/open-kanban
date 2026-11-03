import type { SupabaseClient } from "@supabase/supabase-js";
import type { BoardLabel } from "@/lib/types";

export interface BoardBirthday {
  id: string;
  board_id: string;
  board_slug: string;
  board_name: string;
  board_time_zone: string;
  name: string;
  birth_month: number;
  birth_day: number;
  advance_days: number | null;
  next_on: string;
  visible: boolean;
  created_at: string;
  updated_at: string;
  version: number;
  labels?: BoardLabel[];
}

export interface BirthdayListResult {
  status: "available" | "unavailable";
  board_id?: string;
  board_slug?: string;
  today?: string;
  birthdays: BoardBirthday[];
}

export interface DeletedBirthday {
  id: string;
  board_id: string;
  board_slug: string;
  board_name: string;
  name: string;
  birth_month: number;
  birth_day: number;
  advance_days: number | null;
  deleted_at: string;
  expires_at: string;
  can_restore: boolean;
}

export interface DeletedBirthdayListResult {
  status: "available" | "unavailable";
  birthdays: DeletedBirthday[];
}

export type BirthdayMutationStatus =
  | "confirmed"
  | "conflict"
  | "unavailable"
  | "expired"
  | "expired_unknown";

export interface BirthdayMutationResult {
  status: BirthdayMutationStatus;
  operation_id?: string;
  birthday_id?: string;
  version?: number;
  current_version?: number;
  deleted_at?: string;
  expires_at?: string;
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

export function listBoardBirthdays(supabase: SupabaseClient, slug: string) {
  return callRpc<BirthdayListResult>(supabase, "list_board_birthdays_p", {
    p_slug: slug,
  });
}

export function listMyBirthdays(
  supabase: SupabaseClient,
  boardId: string | null = null,
) {
  return callRpc<BirthdayListResult>(supabase, "list_my_birthdays_p", {
    p_board_id: boardId,
  });
}

export function listDeletedBirthdays(
  supabase: SupabaseClient,
  boardId: string | null = null,
) {
  return callRpc<DeletedBirthdayListResult>(
    supabase,
    "list_deleted_birthdays_p",
    { p_board_id: boardId },
  );
}

export function createBirthday(
  supabase: SupabaseClient,
  command: {
    operationId: string;
    slug: string;
    name: string;
    birthMonth: number;
    birthDay: number;
    advanceDays: number | null;
  },
) {
  return callRpc<BirthdayMutationResult & { birthday?: BoardBirthday }>(
    supabase,
    "create_birthday_p",
    {
      p_operation_id: command.operationId,
      p_slug: command.slug,
      p_name: command.name,
      p_birth_month: command.birthMonth,
      p_birth_day: command.birthDay,
      p_advance_days: command.advanceDays,
    },
  );
}

export function updateBirthday(
  supabase: SupabaseClient,
  command: {
    operationId: string;
    slug: string;
    birthdayId: string;
    expectedVersion: number;
    name: string;
    birthMonth: number;
    birthDay: number;
    advanceDays: number | null;
  },
) {
  return callRpc<BirthdayMutationResult>(supabase, "update_birthday_p", {
    p_operation_id: command.operationId,
    p_slug: command.slug,
    p_birthday_id: command.birthdayId,
    p_expected_version: command.expectedVersion,
    p_name: command.name,
    p_birth_month: command.birthMonth,
    p_birth_day: command.birthDay,
    p_advance_days: command.advanceDays,
  });
}

export function deleteBirthday(
  supabase: SupabaseClient,
  command: {
    operationId: string;
    slug: string;
    birthdayId: string;
    expectedVersion: number;
  },
) {
  return callRpc<BirthdayMutationResult>(supabase, "delete_birthday_p", {
    p_operation_id: command.operationId,
    p_slug: command.slug,
    p_birthday_id: command.birthdayId,
    p_expected_version: command.expectedVersion,
  });
}

export function restoreBirthday(
  supabase: SupabaseClient,
  command: { operationId: string; slug: string; birthdayId: string },
) {
  return callRpc<BirthdayMutationResult>(supabase, "restore_birthday_p", {
    p_operation_id: command.operationId,
    p_slug: command.slug,
    p_birthday_id: command.birthdayId,
  });
}
