"use server";

import { revalidatePath } from "next/cache";
import { resolveApplicationAccess } from "@/lib/auth";
import {
  acceptBoardInvitationLink,
  acceptDirectBoardInvitation,
  BoardInvitationError,
  createBoardInvitationLink,
  createDirectBoardInvitation,
  listBoardInvitations,
  listMyPendingBoardInvitations,
  previewBoardInvitation,
  rejectDirectBoardInvitation,
  renewBoardInvitation,
  revokeBoardInvitation,
} from "@/lib/db/invitations";
import type { InvitationPreview } from "@/lib/invitation-contract";
import { createClient } from "@/lib/supabase/server";
import {
  invitationEmailSchema,
  invitationIdSchema,
  invitationOperationIdSchema,
  invitationTokenSchema,
  slugSchema,
} from "@/lib/validations";

type ActionResult<T> =
  | { status: "ok"; data: T; message?: string }
  | { status: "unavailable"; message: string };

async function getActiveClient() {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) return null;
  const access = await resolveApplicationAccess(supabase);
  return access.status === "active" ? supabase : null;
}

function requestErrorMessage(error: unknown): string {
  if (error instanceof BoardInvitationError && error.code === "42501") {
    return "Tu acceso o los permisos cambiaron. Actualiza la página e inténtalo de nuevo.";
  }
  return "No se pudo confirmar el cambio. Revisa el estado e inténtalo de nuevo.";
}

export async function loadBoardInvitations(
  slug: string,
): Promise<ActionResult<Awaited<ReturnType<typeof listBoardInvitations>>>> {
  if (!slugSchema.safeParse(slug).success) {
    return {
      status: "unavailable",
      message: "No se pudieron cargar las invitaciones.",
    };
  }
  const supabase = await getActiveClient();
  if (!supabase) {
    return {
      status: "unavailable",
      message: "Inicia sesión para ver las invitaciones.",
    };
  }
  try {
    return { status: "ok", data: await listBoardInvitations(supabase, slug) };
  } catch (error) {
    return { status: "unavailable", message: requestErrorMessage(error) };
  }
}

export async function loadMyPendingInvitations(): Promise<
  ActionResult<Awaited<ReturnType<typeof listMyPendingBoardInvitations>>>
> {
  const supabase = await getActiveClient();
  if (!supabase) {
    return {
      status: "unavailable",
      message: "Inicia sesión para ver las invitaciones.",
    };
  }
  try {
    return {
      status: "ok",
      data: await listMyPendingBoardInvitations(supabase),
    };
  } catch (error) {
    return { status: "unavailable", message: requestErrorMessage(error) };
  }
}

export async function createDirectInvitation(
  slug: string,
  email: string,
): Promise<
  ActionResult<Awaited<ReturnType<typeof createDirectBoardInvitation>>>
> {
  const parsedSlug = slugSchema.safeParse(slug);
  const parsedEmail = invitationEmailSchema.safeParse(email);
  if (!parsedSlug.success || !parsedEmail.success) {
    return {
      status: "unavailable",
      message: "Escribe el correo exacto de una persona habilitada.",
    };
  }
  const supabase = await getActiveClient();
  if (!supabase) {
    return {
      status: "unavailable",
      message: "Inicia sesión para invitar a alguien.",
    };
  }
  try {
    const data = await createDirectBoardInvitation(
      supabase,
      parsedSlug.data,
      parsedEmail.data,
    );
    revalidatePath(`/${parsedSlug.data}`);
    revalidatePath("/");
    return { status: "ok", data };
  } catch (error) {
    return { status: "unavailable", message: requestErrorMessage(error) };
  }
}

export async function createInvitationLink(
  slug: string,
  operationId: string,
  token: string,
): Promise<
  ActionResult<Awaited<ReturnType<typeof createBoardInvitationLink>>>
> {
  const parsedSlug = slugSchema.safeParse(slug);
  const parsedOperationId = invitationOperationIdSchema.safeParse(operationId);
  const parsedToken = invitationTokenSchema.safeParse(token);
  if (
    !parsedSlug.success ||
    !parsedOperationId.success ||
    !parsedToken.success
  ) {
    return { status: "unavailable", message: "No se pudo crear el enlace." };
  }
  const supabase = await getActiveClient();
  if (!supabase) {
    return {
      status: "unavailable",
      message: "Inicia sesión para crear un enlace.",
    };
  }
  try {
    const data = await createBoardInvitationLink(
      supabase,
      parsedSlug.data,
      parsedOperationId.data,
      parsedToken.data,
    );
    revalidatePath(`/${parsedSlug.data}`);
    return {
      status: "ok",
      data,
      message: "Enlace creado. Caduca en 72 horas y se usa una sola vez.",
    };
  } catch (error) {
    return { status: "unavailable", message: requestErrorMessage(error) };
  }
}

export async function revokeInvitation(
  slug: string,
  invitationId: string,
): Promise<ActionResult<boolean>> {
  const parsedSlug = slugSchema.safeParse(slug);
  const parsedId = invitationIdSchema.safeParse(invitationId);
  if (!parsedSlug.success || !parsedId.success) {
    return {
      status: "unavailable",
      message: "No se pudo revocar la invitación.",
    };
  }
  const supabase = await getActiveClient();
  if (!supabase) {
    return {
      status: "unavailable",
      message: "Inicia sesión para administrar invitaciones.",
    };
  }
  try {
    const data = await revokeBoardInvitation(supabase, parsedId.data);
    revalidatePath(`/${parsedSlug.data}`);
    return data
      ? { status: "ok", data, message: "Invitación revocada." }
      : {
          status: "unavailable",
          message: "La invitación ya no está disponible.",
        };
  } catch (error) {
    return { status: "unavailable", message: requestErrorMessage(error) };
  }
}

export async function renewInvitation(
  slug: string,
  invitationId: string,
  operationId: string,
  token: string | null,
): Promise<ActionResult<Awaited<ReturnType<typeof renewBoardInvitation>>>> {
  const parsedSlug = slugSchema.safeParse(slug);
  const parsedId = invitationIdSchema.safeParse(invitationId);
  const parsedOperationId = invitationOperationIdSchema.safeParse(operationId);
  const parsedToken =
    token === null
      ? { success: true as const, data: null }
      : invitationTokenSchema.safeParse(token);
  if (
    !parsedSlug.success ||
    !parsedId.success ||
    !parsedOperationId.success ||
    !parsedToken.success
  ) {
    return {
      status: "unavailable",
      message: "No se pudo renovar la invitación.",
    };
  }
  const supabase = await getActiveClient();
  if (!supabase) {
    return {
      status: "unavailable",
      message: "Inicia sesión para administrar invitaciones.",
    };
  }
  try {
    const data = await renewBoardInvitation(
      supabase,
      parsedId.data,
      parsedOperationId.data,
      parsedToken.data,
    );
    revalidatePath(`/${parsedSlug.data}`);
    return { status: "ok", data };
  } catch (error) {
    return { status: "unavailable", message: requestErrorMessage(error) };
  }
}

export async function previewInvitationLink(
  token: string,
): Promise<ActionResult<InvitationPreview>> {
  if (!invitationTokenSchema.safeParse(token).success) {
    return { status: "ok", data: { status: "unavailable" } };
  }
  const supabase = await getActiveClient();
  if (!supabase) {
    return { status: "ok", data: { status: "unavailable" } };
  }
  try {
    return {
      status: "ok",
      data: await previewBoardInvitation(supabase, token),
    };
  } catch {
    return { status: "ok", data: { status: "unavailable" } };
  }
}

export async function acceptDirectInvitation(
  invitationId: string,
  operationId: string,
): Promise<
  ActionResult<Awaited<ReturnType<typeof acceptDirectBoardInvitation>>>
> {
  const parsedId = invitationIdSchema.safeParse(invitationId);
  const parsedOperationId = invitationOperationIdSchema.safeParse(operationId);
  if (!parsedId.success || !parsedOperationId.success) {
    return {
      status: "unavailable",
      message: "Esta invitación ya no está disponible.",
    };
  }
  const supabase = await getActiveClient();
  if (!supabase) {
    return {
      status: "unavailable",
      message: "Tu cuenta todavía no tiene acceso a OpenKanban.",
    };
  }
  try {
    return {
      status: "ok",
      data: await acceptDirectBoardInvitation(
        supabase,
        parsedId.data,
        parsedOperationId.data,
      ),
    };
  } catch (error) {
    return { status: "unavailable", message: requestErrorMessage(error) };
  }
}

export async function acceptInvitationLink(
  token: string,
  operationId: string,
): Promise<
  ActionResult<Awaited<ReturnType<typeof acceptBoardInvitationLink>>>
> {
  const parsedToken = invitationTokenSchema.safeParse(token);
  const parsedOperationId = invitationOperationIdSchema.safeParse(operationId);
  if (!parsedToken.success || !parsedOperationId.success) {
    return { status: "ok", data: { status: "unavailable" } };
  }
  const supabase = await getActiveClient();
  if (!supabase) {
    return {
      status: "unavailable",
      message: "Tu cuenta todavía no tiene acceso a OpenKanban.",
    };
  }
  try {
    const data = await acceptBoardInvitationLink(
      supabase,
      parsedToken.data,
      parsedOperationId.data,
    );
    if (data.status === "accepted" || data.status === "already_member") {
      revalidatePath("/");
    }
    return { status: "ok", data };
  } catch (error) {
    return { status: "unavailable", message: requestErrorMessage(error) };
  }
}

export async function rejectInvitation(
  invitationId: string,
): Promise<ActionResult<boolean>> {
  const parsedId = invitationIdSchema.safeParse(invitationId);
  if (!parsedId.success) {
    return {
      status: "unavailable",
      message: "Esta invitación ya no está disponible.",
    };
  }
  const supabase = await getActiveClient();
  if (!supabase) {
    return {
      status: "unavailable",
      message: "Tu cuenta todavía no tiene acceso a OpenKanban.",
    };
  }
  try {
    const data = await rejectDirectBoardInvitation(supabase, parsedId.data);
    revalidatePath("/");
    return data
      ? { status: "ok", data, message: "Invitación rechazada." }
      : {
          status: "unavailable",
          message: "Esta invitación ya no está disponible.",
        };
  } catch (error) {
    return { status: "unavailable", message: requestErrorMessage(error) };
  }
}
