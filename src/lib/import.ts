import "server-only";

import {
  MAX_LEGACY_BOARD_IMPORT_BYTES,
  parseLegacyBoardImport,
  validateLegacyBoardImportSize,
} from "@/lib/legacy-board-import";

export { parseLegacyBoardImport, validateLegacyBoardImportSize };
export type { LegacyBoardImport } from "@/lib/legacy-board-import";

export const MAX_LEGACY_IMPORT_REQUEST_BYTES =
  MAX_LEGACY_BOARD_IMPORT_BYTES + 65536;

export async function readBoundedRequestBody(
  request: Request,
  maxBytes = MAX_LEGACY_IMPORT_REQUEST_BYTES,
): Promise<ArrayBuffer | null> {
  if (!request.body) return new ArrayBuffer(0);
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const body = new ArrayBuffer(totalBytes);
  const view = new Uint8Array(body);
  let offset = 0;
  for (const chunk of chunks) {
    view.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

export async function readLegacyBoardImportFile(file: File): Promise<{
  sourceSha256: string;
  document: ReturnType<typeof parseLegacyBoardImport>;
}> {
  validateLegacyBoardImportSize(file.size);
  let bytes: Uint8Array<ArrayBuffer>;
  let text: string;
  try {
    bytes = new Uint8Array(await file.arrayBuffer());
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new Error("El archivo no contiene texto UTF-8 válido.");
  }

  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    throw new Error("El archivo no contiene JSON válido.");
  }

  let document: ReturnType<typeof parseLegacyBoardImport>;
  try {
    document = parseLegacyBoardImport(raw);
  } catch {
    throw new Error("El respaldo no cumple el formato v1.");
  }
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const sourceSha256 = Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  return { document, sourceSha256 };
}
