import type { SupabaseClient } from "@supabase/supabase-js";
import {
  type InvitationPreview,
  parseInvitationPreview,
} from "@/lib/invitation-contract";
import { slugSchema } from "@/lib/validations";

export interface BoardInvitation {
  id: string;
  invitation_type: "direct" | "generic";
  recipient_email: string | null;
  expires_at: string;
  invitation_status: "pending" | "expired" | "revoked";
}

export interface PendingBoardInvitation {
  id: string;
  board_name: string;
  inviter_email: string;
  expires_at: string;
}

export type DirectInvitationResult =
  | { status: "already_member" }
  | {
      status: "created" | "existing" | "expired";
      id: string;
      expires_at: string;
    };

export type InvitationLinkResult =
  | { status: "unavailable" }
  | { status: "expired_unknown" }
  | {
      status: "created";
      id: string;
      token: string;
      expires_at: string;
      role: "collaborator";
    };

export type InvitationAcceptanceResult =
  | { status: "unavailable" }
  | { status: "expired_unknown" }
  | { status: "accepted" | "already_member"; board_slug: string };

export type InvitationRenewalResult =
  | { status: "unavailable" }
  | { status: "expired_unknown" }
  | { status: "not_expired" }
  | {
      status: "renewed";
      id: string;
      expires_at: string;
      token?: string;
      role?: "collaborator";
    };

export class BoardInvitationError extends Error {
  constructor(readonly code: string | undefined) {
    super("Board invitation request failed");
    this.name = "BoardInvitationError";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isText(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function parseDirectInvitationResult(value: unknown): DirectInvitationResult {
  if (!isRecord(value)) throw new BoardInvitationError(undefined);
  if (value.status === "already_member") return { status: "already_member" };
  if (
    (value.status === "created" ||
      value.status === "existing" ||
      value.status === "expired") &&
    isText(value.id) &&
    isText(value.expires_at)
  ) {
    return {
      status: value.status,
      id: value.id,
      expires_at: value.expires_at,
    };
  }
  throw new BoardInvitationError(undefined);
}

function parseInvitationLinkResult(value: unknown): InvitationLinkResult {
  if (
    isRecord(value) &&
    (value.status === "unavailable" || value.status === "expired_unknown")
  ) {
    return { status: value.status };
  }
  if (
    !isRecord(value) ||
    value.status !== "created" ||
    !isText(value.id) ||
    !isText(value.token) ||
    !/^[0-9a-f]{64}$/.test(value.token) ||
    !isText(value.expires_at) ||
    value.role !== "collaborator"
  ) {
    throw new BoardInvitationError(undefined);
  }
  return {
    status: value.status,
    id: value.id,
    token: value.token,
    expires_at: value.expires_at,
    role: "collaborator",
  };
}

function parseAcceptanceResult(value: unknown): InvitationAcceptanceResult {
  if (
    isRecord(value) &&
    (value.status === "unavailable" || value.status === "expired_unknown")
  ) {
    return { status: value.status };
  }
  if (
    isRecord(value) &&
    (value.status === "accepted" || value.status === "already_member") &&
    isText(value.board_slug) &&
    slugSchema.safeParse(value.board_slug).success
  ) {
    return { status: value.status, board_slug: value.board_slug };
  }
  throw new BoardInvitationError(undefined);
}

function parseRenewalResult(value: unknown): InvitationRenewalResult {
  if (
    isRecord(value) &&
    (value.status === "unavailable" ||
      value.status === "expired_unknown" ||
      value.status === "not_expired")
  ) {
    return { status: value.status };
  }
  if (
    !isRecord(value) ||
    value.status !== "renewed" ||
    !isText(value.id) ||
    !isText(value.expires_at)
  ) {
    throw new BoardInvitationError(undefined);
  }
  if (value.token !== undefined) {
    if (
      !isText(value.token) ||
      !/^[0-9a-f]{64}$/.test(value.token) ||
      value.role !== "collaborator"
    ) {
      throw new BoardInvitationError(undefined);
    }
    return {
      status: "renewed",
      id: value.id,
      expires_at: value.expires_at,
      token: value.token,
      role: "collaborator",
    };
  }
  return { status: "renewed", id: value.id, expires_at: value.expires_at };
}

function parseBoardInvitationList(value: unknown): BoardInvitation[] {
  if (!Array.isArray(value)) throw new BoardInvitationError(undefined);
  return value.map((entry) => {
    if (
      !isRecord(entry) ||
      !isText(entry.id) ||
      (entry.invitation_type !== "direct" &&
        entry.invitation_type !== "generic") ||
      !(
        entry.recipient_email === null ||
        typeof entry.recipient_email === "string"
      ) ||
      !isText(entry.expires_at) ||
      (entry.invitation_status !== "pending" &&
        entry.invitation_status !== "expired" &&
        entry.invitation_status !== "revoked")
    ) {
      throw new BoardInvitationError(undefined);
    }
    return {
      id: entry.id,
      invitation_type: entry.invitation_type,
      recipient_email: entry.recipient_email,
      expires_at: entry.expires_at,
      invitation_status: entry.invitation_status,
    };
  });
}

function parsePendingInvitations(value: unknown): PendingBoardInvitation[] {
  if (!Array.isArray(value)) throw new BoardInvitationError(undefined);
  return value.map((entry) => {
    if (
      !isRecord(entry) ||
      !isText(entry.id) ||
      !isText(entry.board_name) ||
      !isText(entry.inviter_email) ||
      !isText(entry.expires_at)
    ) {
      throw new BoardInvitationError(undefined);
    }
    return {
      id: entry.id,
      board_name: entry.board_name,
      inviter_email: entry.inviter_email,
      expires_at: entry.expires_at,
    };
  });
}

async function readRpc<T>(
  request: PromiseLike<{ data: unknown; error: { code?: string } | null }>,
  parse: (data: unknown) => T,
): Promise<T> {
  const { data, error } = await request;
  if (error) throw new BoardInvitationError(error.code);
  return parse(data);
}

export async function listBoardInvitations(
  supabase: SupabaseClient,
  slug: string,
): Promise<BoardInvitation[]> {
  return readRpc(
    supabase.rpc("list_board_invitations_p", { p_slug: slug }),
    parseBoardInvitationList,
  );
}

export async function listMyPendingBoardInvitations(
  supabase: SupabaseClient,
): Promise<PendingBoardInvitation[]> {
  return readRpc(
    supabase.rpc("list_my_pending_board_invitations_p"),
    parsePendingInvitations,
  );
}

export async function previewBoardInvitation(
  supabase: SupabaseClient,
  token: string,
): Promise<InvitationPreview> {
  return readRpc(
    supabase.rpc("preview_board_invitation_p", { p_token: token }),
    parseInvitationPreview,
  );
}

export async function createDirectBoardInvitation(
  supabase: SupabaseClient,
  slug: string,
  email: string,
): Promise<DirectInvitationResult> {
  return readRpc(
    supabase.rpc("create_direct_board_invitation_p", {
      p_slug: slug,
      p_email: email,
    }),
    parseDirectInvitationResult,
  );
}

export async function createBoardInvitationLink(
  supabase: SupabaseClient,
  slug: string,
  operationId: string,
  token: string,
): Promise<InvitationLinkResult> {
  return readRpc(
    supabase.rpc("create_board_invitation_link_p", {
      p_slug: slug,
      p_operation_id: operationId,
      p_token: token,
    }),
    parseInvitationLinkResult,
  );
}

export async function acceptDirectBoardInvitation(
  supabase: SupabaseClient,
  invitationId: string,
  operationId: string,
): Promise<InvitationAcceptanceResult> {
  return readRpc(
    supabase.rpc("accept_direct_board_invitation_p", {
      p_invitation_id: invitationId,
      p_operation_id: operationId,
    }),
    parseAcceptanceResult,
  );
}

export async function acceptBoardInvitationLink(
  supabase: SupabaseClient,
  token: string,
  operationId: string,
): Promise<InvitationAcceptanceResult> {
  return readRpc(
    supabase.rpc("accept_board_invitation_link_p", {
      p_token: token,
      p_operation_id: operationId,
    }),
    parseAcceptanceResult,
  );
}

export async function rejectDirectBoardInvitation(
  supabase: SupabaseClient,
  invitationId: string,
): Promise<boolean> {
  return readRpc(
    supabase.rpc("reject_direct_board_invitation_p", {
      p_invitation_id: invitationId,
    }),
    (value) => {
      if (typeof value !== "boolean") throw new BoardInvitationError(undefined);
      return value;
    },
  );
}

export async function revokeBoardInvitation(
  supabase: SupabaseClient,
  invitationId: string,
): Promise<boolean> {
  return readRpc(
    supabase.rpc("revoke_board_invitation_p", {
      p_invitation_id: invitationId,
    }),
    (value) => {
      if (typeof value !== "boolean") throw new BoardInvitationError(undefined);
      return value;
    },
  );
}

export async function renewBoardInvitation(
  supabase: SupabaseClient,
  invitationId: string,
  operationId: string,
  token: string | null,
): Promise<InvitationRenewalResult> {
  return readRpc(
    supabase.rpc("renew_board_invitation_p", {
      p_invitation_id: invitationId,
      p_operation_id: operationId,
      p_token: token,
    }),
    parseRenewalResult,
  );
}
