export interface AdminTaskAttachmentStorageSummary {
  limit_bytes: number;
  used_bytes: number;
  active_bytes: number;
  recoverable_bytes: number;
  reserved_bytes: number;
  pending_bytes: number;
  active_count: number;
  recoverable_count: number;
  reserved_count: number;
  pending_count: number;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSafeCount(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

export function parseAdminTaskAttachmentStorageSummary(
  value: unknown,
): AdminTaskAttachmentStorageSummary | null {
  if (!isRecord(value) || value.status !== "ok") return null;
  if (
    !isSafeCount(value.limit_bytes) ||
    !isSafeCount(value.used_bytes) ||
    !isSafeCount(value.active_bytes) ||
    !isSafeCount(value.recoverable_bytes) ||
    !isSafeCount(value.reserved_bytes) ||
    !isSafeCount(value.pending_bytes) ||
    !isSafeCount(value.active_count) ||
    !isSafeCount(value.recoverable_count) ||
    !isSafeCount(value.reserved_count) ||
    !isSafeCount(value.pending_count)
  ) {
    return null;
  }

  return {
    limit_bytes: value.limit_bytes,
    used_bytes: value.used_bytes,
    active_bytes: value.active_bytes,
    recoverable_bytes: value.recoverable_bytes,
    reserved_bytes: value.reserved_bytes,
    pending_bytes: value.pending_bytes,
    active_count: value.active_count,
    recoverable_count: value.recoverable_count,
    reserved_count: value.reserved_count,
    pending_count: value.pending_count,
  };
}
