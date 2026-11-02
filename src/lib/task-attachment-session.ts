import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { resolveApplicationAccess } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export interface TaskAttachmentSession {
  actorId: string;
  isAdmin: boolean;
  client: SupabaseClient;
}

export async function getTaskAttachmentSession(): Promise<TaskAttachmentSession | null> {
  const client = await createClient();
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) return null;
  const access = await resolveApplicationAccess(client);
  if (access.status !== "active") return null;
  return { actorId: data.user.id, isAdmin: access.isAdmin, client };
}
