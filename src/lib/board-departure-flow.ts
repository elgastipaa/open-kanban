import type { AssignableBoardMember } from "@/lib/types";
import { createSubmissionGate } from "./submission-gate.mjs";

export interface BoardDepartureOptions {
  role: "owner" | "collaborator";
  actorId: string;
  hasOtherCurrentMembers: boolean | null;
  eligibleSuccessors: AssignableBoardMember[] | null;
}

export type BoardDepartureFlow =
  | { status: "closed" }
  | {
      status: "blocked";
      reason:
        | "membership_status_unavailable"
        | "successor_list_unavailable"
        | "no_eligible_successor";
    }
  | {
      status: "review";
      action: "leave" | "transfer" | "delete_last_member";
      eligibleSuccessors: AssignableBoardMember[];
      successor_user_id: string | null;
    };

export type BoardDepartureCommand =
  | {
      action: "leave";
      operation_id: string;
      board_id: string;
      successor_user_id: string | null;
    }
  | {
      action: "delete_last_member";
      operation_id: string;
      board_id: string;
    };

export type BoardDepartureSubmitResult =
  | {
      status:
        | "confirmed"
        | "conflict"
        | "unavailable"
        | "retryable"
        | "expired_unknown";
    }
  | { status: "recoverable"; expires_at?: string }
  | {
      status: "access_denied" | "operation_conflict" | "rejected";
      message: string;
    };

export function createBoardDepartureFlow(
  options: BoardDepartureOptions,
): BoardDepartureFlow {
  if (options.role === "collaborator") {
    return {
      status: "review",
      action: "leave",
      eligibleSuccessors: [],
      successor_user_id: null,
    };
  }

  if (options.hasOtherCurrentMembers === null) {
    return { status: "blocked", reason: "membership_status_unavailable" };
  }
  if (!options.hasOtherCurrentMembers) {
    return {
      status: "review",
      action: "delete_last_member",
      eligibleSuccessors: [],
      successor_user_id: null,
    };
  }

  if (options.eligibleSuccessors === null) {
    return { status: "blocked", reason: "successor_list_unavailable" };
  }

  const eligibleSuccessors = options.eligibleSuccessors.filter(
    (member) =>
      member.user_id !== options.actorId && member.role === "collaborator",
  );
  if (eligibleSuccessors.length === 0) {
    return { status: "blocked", reason: "no_eligible_successor" };
  }
  return {
    status: "review",
    action: "transfer",
    eligibleSuccessors,
    successor_user_id: null,
  };
}

export type BoardDepartureResultStatus =
  | BoardDepartureSubmitResult["status"]
  | "already_submitting"
  | "not_ready";

export type BoardDepartureResultEffect =
  | "leave_context"
  | "refresh_review"
  | "retry_same_command"
  | "block_expired_intent"
  | "show_rejection"
  | "ignore";

export function getBoardDepartureResultEffect(
  status: BoardDepartureResultStatus,
): BoardDepartureResultEffect {
  switch (status) {
    case "confirmed":
    case "recoverable":
    case "access_denied":
    case "unavailable":
      return "leave_context";
    case "conflict":
      return "refresh_review";
    case "retryable":
      return "retry_same_command";
    case "expired_unknown":
      return "block_expired_intent";
    case "operation_conflict":
    case "rejected":
      return "show_rejection";
    case "already_submitting":
    case "not_ready":
      return "ignore";
  }
}

const expiredUnknownIntents = new Map<string, BoardDepartureCommand>();

function departureIntentKey(
  actorId: string,
  command: BoardDepartureCommand,
): string {
  return JSON.stringify([actorId, command.board_id]);
}

export function rememberExpiredUnknownBoardDeparture(
  actorId: string,
  command: BoardDepartureCommand,
): void {
  expiredUnknownIntents.set(departureIntentKey(actorId, command), command);
}

export function getExpiredUnknownBoardDeparture(
  actorId: string,
  command: BoardDepartureCommand,
): BoardDepartureCommand | null {
  return (
    expiredUnknownIntents.get(departureIntentKey(actorId, command)) ?? null
  );
}

export function cancelBoardDeparture(
  _flow: BoardDepartureFlow,
): BoardDepartureFlow {
  return { status: "closed" };
}

export function selectBoardDepartureSuccessor(
  flow: BoardDepartureFlow,
  successorUserId: string,
): BoardDepartureFlow {
  if (flow.status !== "review" || flow.action !== "transfer") return flow;
  if (
    !flow.eligibleSuccessors.some(
      (member) => member.user_id === successorUserId,
    )
  ) {
    return flow;
  }
  return { ...flow, successor_user_id: successorUserId };
}

export function createBoardDepartureCommand(
  flow: BoardDepartureFlow,
  boardId: string,
  operationId: string,
): BoardDepartureCommand | null {
  if (flow.status !== "review") return null;
  if (flow.action === "transfer" && !flow.successor_user_id) return null;
  if (flow.action === "delete_last_member") {
    return {
      action: "delete_last_member",
      operation_id: operationId,
      board_id: boardId,
    };
  }
  return {
    action: "leave",
    operation_id: operationId,
    board_id: boardId,
    successor_user_id:
      flow.action === "transfer" ? flow.successor_user_id : null,
  };
}

export async function confirmBoardDeparture<Result>(
  flow: BoardDepartureFlow,
  boardId: string,
  operationId: string,
  submit: (command: BoardDepartureCommand) => Promise<Result>,
): Promise<Result | { status: "not_ready" }> {
  const command = createBoardDepartureCommand(flow, boardId, operationId);
  if (!command) return { status: "not_ready" };
  return submit(command);
}

export function createBoardDepartureSubmissionGate() {
  return createSubmissionGate();
}
