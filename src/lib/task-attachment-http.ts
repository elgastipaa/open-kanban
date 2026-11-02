export type AttachmentBodyReadResult =
  | { ok: true; bytes: Uint8Array }
  | { ok: false; reason: "size" | "read" };

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

export async function readTaskAttachmentBody(
  body: ReadableStream<Uint8Array> | null,
  maximumBytes = 24_000,
): Promise<AttachmentBodyReadResult> {
  if (!body) return { ok: true, bytes: new Uint8Array() };

  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maximumBytes) {
        await reader.cancel();
        return { ok: false, reason: "size" };
      }
      chunks.push(value);
    }
  } catch {
    return { ok: false, reason: "read" };
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { ok: true, bytes };
}

export async function readTaskAttachmentOperationId(
  request: Request,
): Promise<string | null> {
  const contentLength = request.headers.get("content-length");
  if (
    contentLength !== null &&
    (!/^\d+$/u.test(contentLength) || Number(contentLength) > 1024)
  ) {
    return null;
  }
  const body = await readTaskAttachmentBody(request.body, 1024);
  if (!body.ok) return null;
  try {
    const value: unknown = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(body.bytes),
    );
    if (
      typeof value !== "object" ||
      value === null ||
      !("operation_id" in value) ||
      typeof value.operation_id !== "string" ||
      !UUID_PATTERN.test(value.operation_id)
    ) {
      return null;
    }
    return value.operation_id.toLowerCase();
  } catch {
    return null;
  }
}

function encodeExtendedFilename(fileName: string): string {
  return encodeURIComponent(fileName).replace(
    /[!'()*]/gu,
    (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

export function attachmentContentDisposition(fileName: string): string {
  const fallback = Array.from(fileName)
    .map((character) =>
      /^[\x20-\x7e]$/u.test(character) && !/["\\]/u.test(character)
        ? character
        : "_",
    )
    .join("")
    .slice(0, 120);
  return `attachment; filename="${fallback || "archivo.txt"}"; filename*=UTF-8''${encodeExtendedFilename(fileName)}`;
}
