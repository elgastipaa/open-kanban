"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod/v4";
import { resolveApplicationAccess } from "@/lib/auth";
import type { BoardMemberRemovalCommand } from "@/lib/board-member-removal-flow";
import { getBoard } from "@/lib/db/boards";
import { createClient } from "@/lib/supabase/server";
import { slugSchema } from "@/lib/validations";

const commandSchema = z
  .object({
    operation_id: z.uuid(),
    board_id: z.uuid(),
    membership_id: z.uuid(),
  })
  .strict();

export type BoardMemberRemovalActionResult =
  | {
      status:
        | "confirmed"
        | "conflict"
        | "unavailable"
        | "retryable"
        | "expired_unknown";
    }
  | {
      status: "access_denied" | "operation_conflict" | "rejected";
      message: string;
    };

function isRemovalRpcResult(value: unknown): value is { status: string } {
  return typeof value === "object" && value !== null && "status" in value;
}

export async function removeBoardCollaborator(
  slug: string,
  command: BoardMemberRemovalCommand,
): Promise<BoardMemberRemovalActionResult> {
  const parsedSlug = slugSchema.safeParse(slug);
  const parsedCommand = commandSchema.safeParse(command);
  if (!parsedSlug.success || !parsedCommand.success) {
    return {
      status: "rejected",
      message: "No se pudo validar el retiro del colaborador.",
    };
  }

  try {
    const supabase = await createClient();
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) {
      return {
        status: "access_denied",
        message: "Tu sesión ya no tiene acceso a este tablero.",
      };
    }
    const access = await resolveApplicationAccess(supabase);
    if (access.status !== "active") {
      return {
        status: "access_denied",
        message: "Tu acceso cambió. Actualiza el tablero antes de continuar.",
      };
    }

    const board = await getBoard(supabase, parsedSlug.data);
    if (
      !board ||
      board.id !== parsedCommand.data.board_id ||
      board.role !== "owner"
    ) {
      return {
        status: "access_denied",
        message: "Tu permiso de propietario cambió. Actualiza el tablero.",
      };
    }

    const { data, error } = await supabase.rpc("remove_board_collaborator_p", {
      p_operation_id: parsedCommand.data.operation_id,
      p_board_id: parsedCommand.data.board_id,
      p_membership_id: parsedCommand.data.membership_id,
    });
    if (error) {
      if (error.code === "42501") {
        return {
          status: "access_denied",
          message: "Tu permiso de propietario cambió. Actualiza el tablero.",
        };
      }
      if (error.code === "23514") {
        return {
          status: "operation_conflict",
          message:
            "Esta confirmación ya se usó con otra persona. Actualiza la lista antes de volver a intentarlo.",
        };
      }
      if (error.code === "22023") {
        return {
          status: "rejected",
          message: "No se pudo confirmar el retiro del colaborador.",
        };
      }
      return { status: "retryable" };
    }

    if (!isRemovalRpcResult(data)) return { status: "retryable" };
    const status = data.status;
    if (
      ![
        "confirmed",
        "conflict",
        "unavailable",
        "retryable",
        "expired_unknown",
      ].includes(status)
    ) {
      return { status: "retryable" };
    }
    if (status !== "retryable") {
      revalidatePath("/");
      revalidatePath(`/${parsedSlug.data}`);
    }
    return { status } as BoardMemberRemovalActionResult;
  } catch {
    return { status: "retryable" };
  }
}
