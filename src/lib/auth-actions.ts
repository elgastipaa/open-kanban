"use server";

import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { resolveApplicationAccess } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/");
}

export async function createOwnedBoard() {
  const supabase = await createClient();
  const { data: user } = await supabase.auth.getUser();
  if (!user.user) redirect("/login");

  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active") redirect("/");

  const slug = `board-${randomUUID()}`;
  const { error } = await supabase.rpc("create_board_p", { p_slug: slug });
  if (error) redirect("/?status=create-error");

  redirect(`/${slug}`);
}
