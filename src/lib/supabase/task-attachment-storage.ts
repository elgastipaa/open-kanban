import "server-only";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export const TASK_ATTACHMENT_BUCKET = "task-attachments";

export function createTaskAttachmentServiceClient(): SupabaseClient {
  const url = process.env.NEXT_PUBLIC_SUPABASE_PUBLIC_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceRoleKey) {
    throw new Error("Attachment service configuration is missing.");
  }

  return createClient(url, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
  });
}
