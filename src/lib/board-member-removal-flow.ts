import type { CurrentBoardMember } from "@/lib/types";
import { createSubmissionGate } from "./submission-gate.mjs";

export type { CurrentBoardMember } from "@/lib/types";

export interface BoardMemberRemovalCommand {
  operation_id: string;
  board_id: string;
  membership_id: string;
}

const expiredUnknownRemovals = new Map<string, BoardMemberRemovalCommand>();

function expiredUnknownRemovalKey(
  actorId: string,
  boardId: string,
  membershipId: string,
): string {
  return JSON.stringify([actorId, boardId, membershipId]);
}

export function rememberExpiredUnknownBoardMemberRemoval(
  actorId: string,
  command: BoardMemberRemovalCommand,
): void {
  expiredUnknownRemovals.set(
    expiredUnknownRemovalKey(actorId, command.board_id, command.membership_id),
    command,
  );
}

export function getExpiredUnknownBoardMemberRemoval(
  actorId: string,
  boardId: string,
  membershipId: string,
): BoardMemberRemovalCommand | null {
  return (
    expiredUnknownRemovals.get(
      expiredUnknownRemovalKey(actorId, boardId, membershipId),
    ) ?? null
  );
}

export function clearExpiredUnknownBoardMemberRemoval(
  actorId: string,
  boardId: string,
  membershipId: string,
): void {
  expiredUnknownRemovals.delete(
    expiredUnknownRemovalKey(actorId, boardId, membershipId),
  );
}

export type BoardMemberRemovalFlow =
  | { status: "roster"; error?: string; message?: string }
  | { status: "confirming"; member: CurrentBoardMember }
  | {
      status: "submitting";
      member: CurrentBoardMember;
      command: BoardMemberRemovalCommand;
    }
  | {
      status: "retryable";
      member: CurrentBoardMember;
      command: BoardMemberRemovalCommand;
      error: string;
    };

export type BoardMemberRemovalResultStatus =
  | "confirmed"
  | "conflict"
  | "unavailable"
  | "retryable"
  | "expired_unknown"
  | "access_denied"
  | "operation_conflict"
  | "rejected";

export function createBoardMemberRemovalFlow(): BoardMemberRemovalFlow {
  return { status: "roster" };
}

export function requestBoardMemberRemoval(
  flow: BoardMemberRemovalFlow,
  actorRole: "owner" | "collaborator",
  member: CurrentBoardMember,
): BoardMemberRemovalFlow {
  if (
    flow.status !== "roster" ||
    actorRole !== "owner" ||
    member.role !== "collaborator" ||
    !member.membership_id ||
    !member.user_id ||
    !member.name
  ) {
    return flow;
  }
  return { status: "confirming", member };
}

export function cancelBoardMemberRemoval(
  flow: BoardMemberRemovalFlow,
): BoardMemberRemovalFlow {
  if (flow.status !== "confirming") return flow;
  return createBoardMemberRemovalFlow();
}

export function createBoardMemberRemovalCommand(
  flow: BoardMemberRemovalFlow,
  boardId: string,
  operationId: string,
): BoardMemberRemovalCommand | null {
  if (
    flow.status !== "confirming" ||
    !boardId ||
    !operationId ||
    flow.member.role !== "collaborator"
  ) {
    return null;
  }
  return {
    operation_id: operationId,
    board_id: boardId,
    membership_id: flow.member.membership_id,
  };
}

export function startBoardMemberRemoval(
  flow: BoardMemberRemovalFlow,
  command: BoardMemberRemovalCommand,
): BoardMemberRemovalFlow {
  if (
    flow.status !== "confirming" ||
    flow.member.role !== "collaborator" ||
    flow.member.membership_id !== command.membership_id
  ) {
    return flow;
  }
  return { status: "submitting", member: flow.member, command };
}

export function retryBoardMemberRemoval(
  flow: BoardMemberRemovalFlow,
): BoardMemberRemovalFlow {
  if (flow.status !== "retryable") return flow;
  return {
    status: "submitting",
    member: flow.member,
    command: flow.command,
  };
}

export function finishBoardMemberRemoval(
  flow: BoardMemberRemovalFlow,
  status: BoardMemberRemovalResultStatus,
): BoardMemberRemovalFlow {
  if (flow.status !== "submitting") return flow;
  if (status === "confirmed") {
    return {
      status: "roster",
      message: `Se retiró el acceso de ${flow.member.name}.`,
    };
  }
  if (status === "retryable") {
    return {
      status: "retryable",
      member: flow.member,
      command: flow.command,
      error:
        "No se pudo confirmar el cambio. Reintenta esta misma operación para reconciliar el resultado.",
    };
  }
  if (status === "conflict" || status === "unavailable") {
    return {
      status: "roster",
      error:
        "La membresía cambió antes de confirmar. Actualizamos la lista; revisa el estado actual.",
    };
  }
  if (status === "expired_unknown") {
    return {
      status: "roster",
      error:
        "Venció el plazo para reconciliar la confirmación. Actualizamos la lista; revisa si la persona todavía figura antes de iniciar otra operación.",
    };
  }
  return {
    status: "roster",
    error:
      status === "access_denied"
        ? "Tu permiso de propietario cambió. Actualiza la lista de miembros."
        : "No se pudo retirar el acceso. Revisa la lista e inténtalo de nuevo.",
  };
}

export async function confirmBoardMemberRemoval<Result>(
  flow: BoardMemberRemovalFlow,
  boardId: string,
  operationId: string,
  submit: (command: BoardMemberRemovalCommand) => Promise<Result>,
): Promise<Result | { status: "not_ready" }> {
  const command = createBoardMemberRemovalCommand(flow, boardId, operationId);
  if (!command) return { status: "not_ready" };
  return submit(command);
}

export function createBoardMemberRemovalSubmissionGate() {
  return createSubmissionGate();
}
