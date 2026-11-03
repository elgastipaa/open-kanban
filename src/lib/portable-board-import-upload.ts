import "server-only";

import { createHash } from "node:crypto";
import { mkdtemp, open, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MAX_PORTABLE_BOARD_IMPORT_BYTES } from "@/lib/portable-board-import-zip";

const WRITE_CHUNK_BYTES = 64 * 1024;

export class PortableBoardImportUploadError extends Error {
  readonly kind: "invalid" | "too_large" | "unavailable";

  constructor(message: string, kind: "invalid" | "too_large" | "unavailable") {
    super(message);
    this.kind = kind;
  }
}

export interface SpoolPortableBoardImport {
  path: string;
  size: number;
  sha256: string;
  cleanup(): Promise<void>;
}

export async function spoolPortableBoardImportRequest(
  request: Request,
): Promise<SpoolPortableBoardImport> {
  if (!request.body) {
    throw new PortableBoardImportUploadError(
      "El paquete ZIP está vacío.",
      "invalid",
    );
  }
  const folder = await mkdtemp(join(tmpdir(), "openkanban-import-v2-"));
  const path = join(folder, "package.zip");
  let handle: Awaited<ReturnType<typeof open>> | null = null;
  const reader = request.body.getReader();
  const digest = createHash("sha256");
  let size = 0;
  try {
    handle = await open(path, "wx", 0o600);
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_PORTABLE_BOARD_IMPORT_BYTES) {
        await reader.cancel();
        throw new PortableBoardImportUploadError(
          "El paquete supera el límite técnico permitido.",
          "too_large",
        );
      }
      digest.update(value);
      let offset = 0;
      while (offset < value.byteLength) {
        const length = Math.min(WRITE_CHUNK_BYTES, value.byteLength - offset);
        const result = await handle.write(
          value,
          offset,
          length,
          size - value.byteLength + offset,
        );
        if (result.bytesWritten !== length) {
          throw new PortableBoardImportUploadError(
            "No se pudo guardar temporalmente el paquete.",
            "unavailable",
          );
        }
        offset += result.bytesWritten;
      }
    }
    if (size === 0) {
      throw new PortableBoardImportUploadError(
        "El paquete ZIP está vacío.",
        "invalid",
      );
    }
    await handle.close();
    handle = null;
    return {
      path,
      size,
      sha256: digest.digest("hex"),
      async cleanup() {
        await rm(folder, { recursive: true, force: true });
      },
    };
  } catch (error) {
    try {
      await reader.cancel();
    } catch {
      // The original read or write error carries the result.
    }
    if (handle) await handle.close();
    await rm(folder, { recursive: true, force: true });
    throw error;
  } finally {
    reader.releaseLock();
  }
}
