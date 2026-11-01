export interface AccessSuspensionCandidate {
  user_id: string;
  email: string;
  is_admin: boolean;
}

export interface AccessSuspensionBoard {
  board_id: string;
  slug: string;
  name: string;
  state: "active" | "recoverable";
  relationship: "owner" | "recovery_owner" | "collaborator";
  active_member_count: number;
  deleted_at: string | null;
  expires_at: string | null;
  recovery_owner_id: string | null;
  recovery_owner_is_active: boolean;
  candidates: AccessSuspensionCandidate[];
}

export interface AccessSuspensionPreview {
  status: "ready" | "unavailable";
  boards: AccessSuspensionBoard[];
}

export type AccessSuspensionResultStatus =
  | "confirmed"
  | "unavailable"
  | "conflict";

export function accessSuspensionResultEffect(
  status: AccessSuspensionResultStatus,
) {
  if (status === "confirmed") {
    return {
      kind: "confirmed" as const,
      clearPreview: true,
      refreshAccess: true,
    };
  }
  return {
    kind:
      status === "unavailable"
        ? ("stale_account" as const)
        : ("stale_preview" as const),
    clearPreview: true,
    refreshAccess: true,
  };
}

function hasExactKeys(value: object, expected: string[]): boolean {
  const actual = Object.keys(value).sort();
  return (
    actual.length === expected.length &&
    actual.every((key, index) => key === [...expected].sort()[index])
  );
}

/** Accept only the metadata contract; private board content fails closed. */
export function parseAccessSuspensionPreview(
  value: unknown,
): AccessSuspensionPreview | null {
  if (
    typeof value !== "object" ||
    value === null ||
    !hasExactKeys(value, ["status", "boards"]) ||
    !("status" in value) ||
    !("boards" in value) ||
    !Array.isArray(value.boards) ||
    (value.status !== "ready" && value.status !== "unavailable")
  ) {
    return null;
  }
  if (value.status === "unavailable" && value.boards.length > 0) return null;

  const boards = value.boards;
  for (const board of boards) {
    if (
      typeof board !== "object" ||
      board === null ||
      !hasExactKeys(board, [
        "board_id",
        "slug",
        "name",
        "state",
        "relationship",
        "active_member_count",
        "deleted_at",
        "expires_at",
        "recovery_owner_id",
        "recovery_owner_is_active",
        "candidates",
      ]) ||
      !(
        "board_id" in board &&
        typeof board.board_id === "string" &&
        "slug" in board &&
        typeof board.slug === "string" &&
        "name" in board &&
        typeof board.name === "string" &&
        "state" in board &&
        (board.state === "active" || board.state === "recoverable") &&
        "relationship" in board &&
        (board.relationship === "owner" ||
          board.relationship === "recovery_owner" ||
          board.relationship === "collaborator") &&
        "active_member_count" in board &&
        typeof board.active_member_count === "number" &&
        Number.isInteger(board.active_member_count) &&
        board.active_member_count >= 0 &&
        "deleted_at" in board &&
        (typeof board.deleted_at === "string" || board.deleted_at === null) &&
        "expires_at" in board &&
        (typeof board.expires_at === "string" || board.expires_at === null) &&
        "recovery_owner_id" in board &&
        (typeof board.recovery_owner_id === "string" ||
          board.recovery_owner_id === null) &&
        "recovery_owner_is_active" in board &&
        typeof board.recovery_owner_is_active === "boolean" &&
        "candidates" in board &&
        Array.isArray(board.candidates)
      ) ||
      (board.state === "active" &&
        (board.deleted_at !== null || board.expires_at !== null)) ||
      (board.state === "recoverable" &&
        (board.deleted_at === null || board.expires_at === null))
    ) {
      return null;
    }

    for (const candidate of board.candidates) {
      if (
        typeof candidate !== "object" ||
        candidate === null ||
        !hasExactKeys(candidate, ["user_id", "email", "is_admin"]) ||
        !("user_id" in candidate) ||
        typeof candidate.user_id !== "string" ||
        !("email" in candidate) ||
        typeof candidate.email !== "string" ||
        !("is_admin" in candidate) ||
        typeof candidate.is_admin !== "boolean"
      ) {
        return null;
      }
    }
  }

  return value as AccessSuspensionPreview;
}

export interface AccessSuspensionResolution {
  board_id: string;
  action:
    | "transfer"
    | "recover"
    | "set_recovery_owner"
    | "leave_recovery_unassigned";
  successor_id: string | null;
}

export type AccessSuspensionDecision =
  | { kind: "ready"; resolutions: AccessSuspensionResolution[] }
  | { kind: "successor_required"; board_ids: string[] }
  | { kind: "successor_invalid"; board_ids: string[] };

/** Build only the explicit ownership choices; membership departures need no owner choice. */
export function prepareAccessSuspensionResolutions(
  boards: AccessSuspensionBoard[],
  selectedSuccessorByBoard: Record<string, string>,
): AccessSuspensionDecision {
  const resolutions: AccessSuspensionResolution[] = [];
  const missingSuccessorBoardIds: string[] = [];
  const invalidSuccessorBoardIds: string[] = [];

  for (const board of [...boards].sort((left, right) =>
    left.board_id.localeCompare(right.board_id),
  )) {
    if (board.relationship === "collaborator") continue;

    if (board.state === "active" && board.relationship === "owner") {
      if (board.candidates.length === 0) {
        resolutions.push({
          board_id: board.board_id,
          action: "recover",
          successor_id: null,
        });
        continue;
      }

      const selectedSuccessorId = selectedSuccessorByBoard[board.board_id];
      if (!selectedSuccessorId) {
        missingSuccessorBoardIds.push(board.board_id);
      } else if (
        !board.candidates.some(
          (candidate) => candidate.user_id === selectedSuccessorId,
        )
      ) {
        invalidSuccessorBoardIds.push(board.board_id);
      } else {
        resolutions.push({
          board_id: board.board_id,
          action: "transfer",
          successor_id: selectedSuccessorId,
        });
      }
      continue;
    }

    if (board.state === "recoverable") {
      if (
        board.relationship === "owner" &&
        board.recovery_owner_is_active &&
        board.recovery_owner_id !== null
      ) {
        continue;
      }
      if (board.candidates.length === 0) {
        resolutions.push({
          board_id: board.board_id,
          action: "leave_recovery_unassigned",
          successor_id: null,
        });
        continue;
      }

      const selectedSuccessorId = selectedSuccessorByBoard[board.board_id];
      if (!selectedSuccessorId) {
        missingSuccessorBoardIds.push(board.board_id);
      } else if (
        !board.candidates.some(
          (candidate) => candidate.user_id === selectedSuccessorId,
        )
      ) {
        invalidSuccessorBoardIds.push(board.board_id);
      } else {
        resolutions.push({
          board_id: board.board_id,
          action: "set_recovery_owner",
          successor_id: selectedSuccessorId,
        });
      }
    }
  }

  if (invalidSuccessorBoardIds.length > 0) {
    return {
      kind: "successor_invalid",
      board_ids: invalidSuccessorBoardIds,
    };
  }
  if (missingSuccessorBoardIds.length > 0) {
    return {
      kind: "successor_required",
      board_ids: missingSuccessorBoardIds,
    };
  }
  return { kind: "ready", resolutions };
}
