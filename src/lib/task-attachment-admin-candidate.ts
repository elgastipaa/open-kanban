export interface AdminTaskAttachmentCleanupCandidate {
  attachment_id: string;
  board_reference: string;
  task_reference: string;
  owner_reference: string | null;
  size_bytes: number;
  created_at: string;
  state: string;
  deletion_cause: string | null;
  task_state: string;
  expires_at: string | null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseAdminTaskAttachmentCleanupCandidate(
  value: unknown,
): AdminTaskAttachmentCleanupCandidate | null {
  if (
    !isRecord(value) ||
    Object.hasOwn(value, "uploaded_by_reference") ||
    typeof value.attachment_id !== "string" ||
    typeof value.board_reference !== "string" ||
    typeof value.task_reference !== "string" ||
    (value.owner_reference !== null &&
      typeof value.owner_reference !== "string") ||
    typeof value.size_bytes !== "number" ||
    typeof value.created_at !== "string" ||
    typeof value.state !== "string" ||
    (value.deletion_cause !== null &&
      typeof value.deletion_cause !== "string") ||
    typeof value.task_state !== "string" ||
    (value.expires_at !== null && typeof value.expires_at !== "string")
  ) {
    return null;
  }

  return {
    attachment_id: value.attachment_id,
    board_reference: value.board_reference,
    task_reference: value.task_reference,
    owner_reference: value.owner_reference,
    size_bytes: value.size_bytes,
    created_at: value.created_at,
    state: value.state,
    deletion_cause: value.deletion_cause,
    task_state: value.task_state,
    expires_at: value.expires_at,
  };
}
