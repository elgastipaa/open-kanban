"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { resolveApplicationAccess } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { createBoardSchema, renameBoardSchema } from "@/lib/validations";

export interface CreateBoardActionState {
  error: string | null;
  slug?: string;
  editable?: boolean;
  uncertain?: boolean;
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/");
}

export async function createOwnedBoard(
  _previousState: CreateBoardActionState,
  formData: FormData,
): Promise<CreateBoardActionState> {
  const input = createBoardSchema.safeParse({
    name: formData.get("name"),
    time_zone: formData.get("time_zone"),
    operation_id: formData.get("operation_id"),
  });
  if (!input.success) {
    return {
      error: "Escribe un nombre y espera a detectar tu zona horaria.",
      editable: true,
    };
  }

  const supabase = await createClient();
  const { data: user } = await supabase.auth.getUser();
  if (!user.user) {
    return { error: "Inicia sesión para crear un tablero.", editable: true };
  }

  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active") {
    return {
      error: "Tu cuenta ya no tiene acceso para crear tableros.",
      editable: true,
    };
  }

  const { data, error } = await supabase
    .rpc("create_board_p", {
      p_name: input.data.name,
      p_time_zone: input.data.time_zone,
      p_operation_id: input.data.operation_id,
    })
    .single();
  const created = data as { slug?: unknown } | null;
  if (error || typeof created?.slug !== "string") {
    const { data: resolvedSlug, error: resolveError } = await supabase.rpc(
      "get_board_creation_result_p",
      { p_operation_id: input.data.operation_id },
    );
    if (!resolveError && typeof resolvedSlug === "string") {
      revalidatePath("/");
      revalidatePath(`/${resolvedSlug}`);
      return { error: null, slug: resolvedSlug };
    }

    const definitelyRejected = ["22023", "42501"].includes(error?.code ?? "");
    return {
      error:
        "No pudimos confirmar la creación. Puedes volver a intentarlo; el envío se resolverá de forma segura.",
      editable: definitelyRejected,
      uncertain: !definitelyRejected,
    };
  }

  revalidatePath("/");
  revalidatePath(`/${created.slug}`);
  return { error: null, slug: created.slug };
}

export async function renameBoard(
  slug: string,
  name: string,
): Promise<{ name?: string; error?: string }> {
  const input = renameBoardSchema.safeParse({ name });
  if (!input.success) return { error: "Escribe un nombre para el tablero." };

  const supabase = await createClient();
  const { data: user } = await supabase.auth.getUser();
  if (!user.user) return { error: "Inicia sesión para cambiar este tablero." };

  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active") {
    return { error: "Tu cuenta ya no tiene acceso para cambiar este tablero." };
  }

  const { data, error } = await supabase
    .rpc("rename_board_p", { p_slug: slug, p_name: input.data.name })
    .single();
  const renamed = data as { name?: unknown } | null;
  if (error || typeof renamed?.name !== "string") {
    return { error: "No se pudo cambiar el nombre. Inténtalo de nuevo." };
  }
  revalidatePath("/");
  revalidatePath(`/${slug}`);
  return { name: renamed.name };
}
