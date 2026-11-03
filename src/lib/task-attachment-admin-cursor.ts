const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const TIMESTAMP_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/iu;

export type AdminTaskAttachmentCursor = {
  createdAt: string;
  attachmentId: string;
};

export function readAdminTaskAttachmentCursor(
  search: URLSearchParams,
): { ok: true; cursor: AdminTaskAttachmentCursor | null } | { ok: false } {
  const createdAtValues = search.getAll("cursor_created_at");
  const attachmentIdValues = search.getAll("cursor_attachment_id");
  if (createdAtValues.length > 1 || attachmentIdValues.length > 1) {
    return { ok: false };
  }
  const createdAt = createdAtValues[0] ?? null;
  const attachmentId = attachmentIdValues[0] ?? null;
  if (createdAt === null && attachmentId === null) {
    return { ok: true, cursor: null };
  }
  if (
    createdAt === null ||
    attachmentId === null ||
    !TIMESTAMP_PATTERN.test(createdAt) ||
    !Number.isFinite(Date.parse(createdAt)) ||
    !UUID_PATTERN.test(attachmentId)
  ) {
    return { ok: false };
  }
  return { ok: true, cursor: { createdAt, attachmentId } };
}
