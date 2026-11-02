import "server-only";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import {
  isTaskAttachmentObjectAbsentFromCompleteInventory,
  TASK_ATTACHMENT_OBJECT_INVENTORY_LIMIT,
} from "@/lib/task-attachment-download";

export const TASK_ATTACHMENT_BUCKET = "task-attachments";
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

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
  if (
    !UUID_PATTERN.test(attachmentId) ||
    objectKey !== `attachments/${attachmentId}`
  ) {
    return false;
  }
  try {
    const { error: removeError } = await service.storage
      .from(TASK_ATTACHMENT_BUCKET)
      .remove([objectKey]);
    if (removeError) return false;
    const { data: objects, error: listError } = await service.storage
      .from(TASK_ATTACHMENT_BUCKET)
      .list("attachments", {
        limit: TASK_ATTACHMENT_OBJECT_INVENTORY_LIMIT,
        search: attachmentId,
      });
    return isTaskAttachmentObjectAbsentFromCompleteInventory(
      objects,
      listError,
      objectKey,
    );
  } catch {
    return false;
  }
}
