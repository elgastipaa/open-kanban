import "server-only";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import {
  removeTaskAttachmentObjectAndConfirmAbsent as removeAndConfirmAbsent,
  TASK_ATTACHMENT_BUCKET,
} from "@/lib/task-attachment-download";

export { TASK_ATTACHMENT_BUCKET };

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

export async function removeTaskAttachmentObjectAndConfirmAbsent(
  service: SupabaseClient,
  attachmentId: string,
  objectKey: string,
): Promise<boolean> {
  return removeAndConfirmAbsent(service, attachmentId, objectKey);
}
