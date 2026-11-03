const NOTICE_THRESHOLDS = new Set([160000000, 200000000]);
const TIMESTAMP_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/iu;

export interface TaskAttachmentCapacityNotice {
  threshold_bytes: 160000000 | 200000000;
  last_notified_at: string;
}

export type TaskAttachmentCapacityNoticeThreshold = 160000000 | 200000000;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseNotice(value: unknown): TaskAttachmentCapacityNotice | null {
  if (
    !isRecord(value) ||
    typeof value.threshold_bytes !== "number" ||
    !NOTICE_THRESHOLDS.has(value.threshold_bytes) ||
    typeof value.last_notified_at !== "string" ||
    !TIMESTAMP_PATTERN.test(value.last_notified_at) ||
    !Number.isFinite(Date.parse(value.last_notified_at))
  ) {
    return null;
  }
  return {
    threshold_bytes: value.threshold_bytes as 160000000 | 200000000,
    last_notified_at: value.last_notified_at,
  };
}

export function parseTaskAttachmentCapacityNotices(
  value: unknown,
): TaskAttachmentCapacityNotice[] | null {
  if (
    !isRecord(value) ||
    value.status !== "ok" ||
    !Array.isArray(value.items)
  ) {
    return null;
  }
  const items = value.items.map(parseNotice);
  if (items.some((item) => item === null)) return null;
  const parsedItems = items as TaskAttachmentCapacityNotice[];
  const thresholds = new Set(parsedItems.map((item) => item.threshold_bytes));
  return thresholds.size === parsedItems.length ? parsedItems : null;
}

export function taskAttachmentCapacityNoticeMessage(
  notice: TaskAttachmentCapacityNotice,
): string {
  const threshold =
    notice.threshold_bytes === 160000000
      ? "El almacenamiento global de adjuntos alcanzó el 80 % (160 MB de 200 MB)."
      : "El almacenamiento global de adjuntos alcanzó el máximo de 200 MB.";
  return `${threshold} Puedes revisar los archivos de tus tableros. El espacio de los archivos en recuperación sigue ocupado durante siete días y solo se libera después de que la purga confirme su eliminación.`;
}

export async function readCapacityNoticeReadRequest(
  request: Request,
): Promise<TaskAttachmentCapacityNoticeThreshold | null> {
  const contentType = request.headers
    .get("content-type")
    ?.split(";", 1)[0]
    .trim()
    .toLowerCase();
  if (contentType !== "application/json") return null;
  const contentLength = request.headers.get("content-length");
  if (
    contentLength !== null &&
    (!/^\d+$/u.test(contentLength) || Number(contentLength) > 256)
  ) {
    return null;
  }
  if (!request.body) return null;

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > 256) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } catch {
    return null;
  } finally {
    reader.releaseLock();
  }

  try {
    const bytes = new Uint8Array(totalBytes);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    const payload: unknown = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    );
    if (
      typeof payload !== "object" ||
      payload === null ||
      Array.isArray(payload) ||
      !("threshold_bytes" in payload) ||
      (payload.threshold_bytes !== 160000000 &&
        payload.threshold_bytes !== 200000000) ||
      Object.keys(payload).some((key) => key !== "threshold_bytes")
    ) {
      return null;
    }
    return payload.threshold_bytes;
  } catch {
    return null;
  }
}
