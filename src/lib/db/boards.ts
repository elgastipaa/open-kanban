import type { SupabaseClient } from "@supabase/supabase-js";
import { isTaskEditReadAccessDeniedCode } from "@/lib/task-edit-read";
import type { Board, BoardTimeZonePreview, ColumnWithTasks } from "@/lib/types";
import { createBoardSchema } from "@/lib/validations";
import { handleSupabaseError } from "./errors";
import { TaskEditError } from "./tasks";

export type BoardTimeZoneErrorReason =
  | "invalid_time_zone"
  | "access_denied"
  | "conflict"
  | "uncertain";

export class BoardSnapshotReadError extends Error {
  constructor(readonly reason: "denied" | "unavailable") {
    super("No se pudo consultar el tablero.");
    this.name = "BoardSnapshotReadError";
  }
}

export interface RecoverableBoard {
  id: string;
  slug: string;
  name: string;
  owner_id: string;
  deleted_at: string;
  expires_at: string;
}

export interface AdminRecoverableBoard extends RecoverableBoard {
  recovery_owner_id: string | null;
  owner_is_valid: boolean;
  active_member_count: number;
  cause:
    | "owner_confirmed_last_member"
    | "owner_requested"
    | "admin_suspended_owner";
}

export interface BoardRecoveryOwner {
  user_id: string;
  email: string;
  is_admin: boolean;
}

export type BoardRecoveryStatus =
  | "recoverable"
  | "confirmed"
  | "owner_required"
  | "expired"
  | "expired_unknown"
  | "retryable"
  | "conflict"
  | "unavailable";

export interface BoardRecoveryResult {
  status: BoardRecoveryStatus;
  operation_id: string;
  expires_at?: string;
  owner_id?: string;
}

export type BoardRecoveryErrorReason =
  | "access_denied"
  | "conflict"
  | "uncertain";

export class BoardRecoveryError extends Error {
  constructor(readonly reason: BoardRecoveryErrorReason) {
    super(reason);
    this.name = "BoardRecoveryError";
  }
}

function boardRecoveryError(error: { code?: string }): BoardRecoveryError {
  if (error.code === "42501") return new BoardRecoveryError("access_denied");
  if (error.code === "23514" || error.code === "55000") {
    return new BoardRecoveryError("conflict");
  }
  return new BoardRecoveryError("uncertain");
}

function isBoardRecoveryResult(value: unknown): value is BoardRecoveryResult {
  return (
    typeof value === "object" &&
    value !== null &&
    "status" in value &&
    typeof value.status === "string" &&
    [
      "recoverable",
      "confirmed",
      "owner_required",
      "expired",
      "expired_unknown",
      "retryable",
      "conflict",
      "unavailable",
    ].includes(value.status) &&
    "operation_id" in value &&
    typeof value.operation_id === "string" &&
    (!("expires_at" in value) || typeof value.expires_at === "string") &&
    (!("owner_id" in value) || typeof value.owner_id === "string")
  );
}

function isRecoverableBoard(value: unknown): value is RecoverableBoard {
  return (
    typeof value === "object" &&
    value !== null &&
    "id" in value &&
    typeof value.id === "string" &&
    "slug" in value &&
    typeof value.slug === "string" &&
    "name" in value &&
    typeof value.name === "string" &&
    "owner_id" in value &&
    typeof value.owner_id === "string" &&
    "deleted_at" in value &&
    typeof value.deleted_at === "string" &&
    "expires_at" in value &&
    typeof value.expires_at === "string"
  );
}

export class BoardTimeZoneError extends Error {
  constructor(readonly reason: BoardTimeZoneErrorReason) {
    super(reason);
    this.name = "BoardTimeZoneError";
  }
}

function boardTimeZoneError(error: { code?: string }): BoardTimeZoneError {
  if (error.code === "42501") return new BoardTimeZoneError("access_denied");
  if (error.code === "22023") {
    return new BoardTimeZoneError("invalid_time_zone");
  }
  if (error.code === "23514") return new BoardTimeZoneError("conflict");
  return new BoardTimeZoneError("uncertain");
}

function isBoardTimeZonePreview(value: unknown): value is BoardTimeZonePreview {
  return (
    typeof value === "object" &&
    value !== null &&
    "time_zone" in value &&
    typeof value.time_zone === "string" &&
    "preview_time_zone" in value &&
    typeof value.preview_time_zone === "string" &&
    "today_before" in value &&
    typeof value.today_before === "string" &&
    "today_after" in value &&
    typeof value.today_after === "string" &&
    "due_today_before" in value &&
    typeof value.due_today_before === "number" &&
    "overdue_before" in value &&
    typeof value.overdue_before === "number" &&
    "due_today_after" in value &&
    typeof value.due_today_after === "number" &&
    "overdue_after" in value &&
    typeof value.overdue_after === "number" &&
    "due_dates_unchanged" in value &&
    value.due_dates_unchanged === true
  );
}

/** Preview date-state changes with the database clock and current board data. */
export async function previewBoardTimeZone(
  supabase: SupabaseClient,
  slug: string,
  timeZone: string,
): Promise<BoardTimeZonePreview> {
  const { data, error } = await supabase.rpc("preview_board_time_zone_p", {
    p_slug: slug,
    p_time_zone: timeZone,
  });
  if (error) throw boardTimeZoneError(error);
  if (!isBoardTimeZonePreview(data)) throw new BoardTimeZoneError("uncertain");
  return data;
}

/** Change only the owner's board zone after the preview is accepted. */
export async function updateBoardTimeZone(
  supabase: SupabaseClient,
  slug: string,
  expectedTimeZone: string,
  timeZone: string,
): Promise<Board> {
  const { data, error } = await supabase.rpc("update_board_time_zone_p", {
    p_slug: slug,
    p_expected_time_zone: expectedTimeZone,
    p_time_zone: timeZone,
  });
  if (error) throw boardTimeZoneError(error);
  if (
    typeof data !== "object" ||
    data === null ||
    !("time_zone" in data) ||
    typeof data.time_zone !== "string" ||
    !("today" in data) ||
    typeof data.today !== "string"
  ) {
    throw new BoardTimeZoneError("uncertain");
  }
  return data as Board;
}

/** Fetch a board by slug, returns null if not found */
export async function getBoard(
  supabase: SupabaseClient,
  slug: string,
): Promise<Board | null> {
  const response = await supabase
    .rpc("get_board_p", { p_slug: slug })
    .maybeSingle();

  if (response.error) handleSupabaseError(response.error);
  return response.data as Board | null;
}

/** Create an explicitly named board with a retry-safe operation id */
export async function createBoard(
  supabase: SupabaseClient,
  input: { name: string; time_zone: string; operation_id: string },
): Promise<Board> {
  const parsed = createBoardSchema.parse(input);

  const response = await supabase
    .rpc("create_board_p", {
      p_name: parsed.name,
      p_time_zone: parsed.time_zone,
      p_operation_id: parsed.operation_id,
    })
    .single();

  if (response.error) handleSupabaseError(response.error);
  return response.data as Board;
}

/** Move an owned board into its seven-day recovery window. */
export async function deleteBoard(
  supabase: SupabaseClient,
  slug: string,
  boardId: string,
  operationId: string,
): Promise<BoardRecoveryResult> {
  const { data, error } = await supabase.rpc("delete_board_p", {
    p_operation_id: operationId,
    p_slug: slug,
    p_id: boardId,
  });
  if (error) throw boardRecoveryError(error);
  if (
    !isBoardRecoveryResult(data) ||
    data.status !== "recoverable" ||
    typeof data.expires_at !== "string"
  ) {
    throw new BoardRecoveryError("uncertain");
  }
  return data;
}

/** List only recoverable boards for their still-enabled current owner. */
export async function listMyRecoverableBoards(
  supabase: SupabaseClient,
): Promise<RecoverableBoard[]> {
  const { data, error } = await supabase.rpc("list_my_recoverable_boards_p");
  if (error) handleSupabaseError(error);
  if (!Array.isArray(data) || !data.every(isRecoverableBoard)) {
    throw new Error("The recoverable board list could not be read.");
  }
  return data;
}

/** List metadata only; global admins never receive board content here. */
export async function listAdminRecoverableBoards(
  supabase: SupabaseClient,
): Promise<AdminRecoverableBoard[]> {
  const { data, error } = await supabase.rpc("admin_list_recoverable_boards_p");
  if (error) handleSupabaseError(error);
  if (
    !Array.isArray(data) ||
    !data.every(
      (board) =>
        isRecoverableBoard(board) &&
        "recovery_owner_id" in board &&
        (typeof board.recovery_owner_id === "string" ||
          board.recovery_owner_id === null) &&
        "owner_is_valid" in board &&
        typeof board.owner_is_valid === "boolean" &&
        "active_member_count" in board &&
        typeof board.active_member_count === "number" &&
        "cause" in board &&
        (board.cause === "owner_confirmed_last_member" ||
          board.cause === "owner_requested" ||
          board.cause === "admin_suspended_owner"),
    )
  ) {
    throw new Error("The administrative recovery list could not be read.");
  }
  return data as AdminRecoverableBoard[];
}

/** Return active identities that an administrator may explicitly assign. */
export async function listBoardRecoveryOwners(
  supabase: SupabaseClient,
  boardId: string,
): Promise<BoardRecoveryOwner[]> {
  const { data, error } = await supabase.rpc("admin_list_recovery_owners_p", {
    p_board_id: boardId,
  });
  if (error) handleSupabaseError(error);
  if (
    !Array.isArray(data) ||
    !data.every(
      (owner) =>
        typeof owner === "object" &&
        owner !== null &&
        "user_id" in owner &&
        typeof owner.user_id === "string" &&
        "email" in owner &&
        typeof owner.email === "string" &&
        "is_admin" in owner &&
        typeof owner.is_admin === "boolean",
    )
  ) {
    throw new Error("The owner choices could not be read.");
  }
  return data as BoardRecoveryOwner[];
}

/** Restore a board without recreating revoked memberships or invitations. */
export async function restoreBoard(
  supabase: SupabaseClient,
  boardId: string,
  operationId: string,
  newOwnerId: string | null = null,
): Promise<BoardRecoveryResult> {
  const { data, error } = await supabase.rpc("restore_board_p", {
    p_operation_id: operationId,
    p_board_id: boardId,
    p_new_owner_id: newOwnerId,
  });
  if (error) throw boardRecoveryError(error);
  if (!isBoardRecoveryResult(data)) throw new BoardRecoveryError("uncertain");
  return data;
}

/** Fetch the complete board state: board + columns with nested tasks */
export async function getFullBoard(
  supabase: SupabaseClient,
  slug: string,
): Promise<{ board: Board; columns: ColumnWithTasks[] } | null> {
  const response = await supabase
    .rpc("get_full_board_p", { p_slug: slug })
    .maybeSingle();

  if (response.error) {
    const reason = isTaskEditReadAccessDeniedCode(response.error.code)
      ? "denied"
      : "unavailable";
    try {
      handleSupabaseError(response.error);
    } catch {
      throw new BoardSnapshotReadError(reason);
    }
  }
  return response.data as { board: Board; columns: ColumnWithTasks[] } | null;
}

/** Read a board for task-edit reconciliation without hiding SQL permission denial. */
export async function getFullBoardForTaskEdit(
  supabase: SupabaseClient,
  slug: string,
): Promise<{ board: Board; columns: ColumnWithTasks[] } | null> {
  const response = await supabase
    .rpc("get_full_board_p", { p_slug: slug })
    .maybeSingle();

  if (response.error) {
    if (isTaskEditReadAccessDeniedCode(response.error.code)) {
      throw new TaskEditError("access_denied");
    }
    handleSupabaseError(response.error);
  }
  return response.data as { board: Board; columns: ColumnWithTasks[] } | null;
}
