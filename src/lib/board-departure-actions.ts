"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod/v4";
import { resolveApplicationAccess } from "@/lib/auth";
import type { BoardDepartureCommand } from "@/lib/board-departure-flow";
import { createClient } from "@/lib/supabase/server";
import { slugSchema } from "@/lib/validations";

const departureCommandSchema = z.discriminatedUnion("action", [
  z
    .object({
      action: z.literal("leave"),
      operation_id: z.uuid(),
      board_id: z.uuid(),
      successor_user_id: z.uuid().nullable(),
    })
    .strict(),
  z
    .object({
      action: z.literal("delete_last_member"),
      operation_id: z.uuid(),
      board_id: z.uuid(),
    })
    .strict(),
]);

type DepartureActionResult =
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

function isDepartureRpcResult(value: unknown): value is {
  status: string;
  expires_at?: string;
} {
  return typeof value === "object" && value !== null && "status" in value;
}

export async function submitBoardDeparture(
  slug: string,
  command: BoardDepartureCommand,
): Promise<DepartureActionResult> {
  const parsedSlug = slugSchema.safeParse(slug);
  const parsedCommand = departureCommandSchema.safeParse(command);
  if (!parsedSlug.success || !parsedCommand.success) {
    return {
      status: "rejected",
      message: "No se pudo validar la salida del tablero.",
    };
  }

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
      message: "Tu acceso cambió. Volveremos a la lista de tableros.",
    };
  }

  try {
    const { data, error } =
      parsedCommand.data.action === "leave"
        ? await supabase.rpc("leave_board_p", {
            p_operation_id: parsedCommand.data.operation_id,
            p_board_id: parsedCommand.data.board_id,
            p_successor_user_id: parsedCommand.data.successor_user_id,
          })
        : await supabase.rpc("delete_last_member_board_p", {
            p_operation_id: parsedCommand.data.operation_id,
            p_board_id: parsedCommand.data.board_id,
          });

    if (error) {
      if (error.code === "42501") {
        return {
          status: "access_denied",
          message: "Tu acceso cambió. Actualiza el tablero antes de continuar.",
        };
      }
      if (error.code === "23514") {
        return {
          status: "operation_conflict",
          message:
            "Esta confirmación ya se usó con otros datos. Revisa la selección antes de volver a intentarlo.",
        };
      }
      if (error.code === "22023") {
        return {
          status: "rejected",
          message: "La salida del tablero necesita una revisión.",
        };
      }
      return { status: "retryable" };
    }

    if (!isDepartureRpcResult(data)) return { status: "retryable" };
    const status = data.status;
    if (
      ![
        "confirmed",
        "conflict",
        "unavailable",
        "retryable",
        "expired_unknown",
        "recoverable",
      ].includes(status)
    ) {
      return { status: "retryable" };
    }
    if (status === "recoverable") {
      if (typeof data.expires_at !== "string") return { status: "retryable" };
      revalidatePath("/");
      revalidatePath(`/${parsedSlug.data}`);
      return { status: "recoverable", expires_at: data.expires_at };
    }
    if (status === "confirmed") {
      revalidatePath("/");
      revalidatePath(`/${parsedSlug.data}`);
    }
    return { status } as DepartureActionResult;
  } catch {
    return { status: "retryable" };
  }
}
