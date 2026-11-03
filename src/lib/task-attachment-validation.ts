import { createHash } from "node:crypto";

export type TaskAttachmentValidationReason =
  | "name"
  | "extension"
  | "empty"
  | "size"
  | "encoding"
  | "binary";

export type TaskAttachmentValidation =
  | { ok: true; fileName: string; sizeBytes: number; sha256: string }
  | { ok: false; reason: TaskAttachmentValidationReason };

const MAX_ATTACHMENT_BYTES = 24_000;

function containsControlCharacters(
  value: string,
  allowTextWhitespace: boolean,
): boolean {
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0;
    if (codePoint <= 0x1f) {
      if (
        allowTextWhitespace &&
        (codePoint === 0x09 || codePoint === 0x0a || codePoint === 0x0d)
      ) {
        continue;
      }
      return true;
    }
    if (codePoint >= 0x7f && codePoint <= 0x9f) return true;
  }
  return false;
}

const BINARY_SIGNATURES: ReadonlyArray<readonly number[]> = [
  [0x25, 0x50, 0x44, 0x46], // PDF
  [0x89, 0x50, 0x4e, 0x47], // PNG
  [0xff, 0xd8, 0xff], // JPEG
  [0x47, 0x49, 0x46, 0x38], // GIF
  [0x50, 0x4b, 0x03, 0x04], // ZIP
  [0x50, 0x4b, 0x05, 0x06],
  [0x50, 0x4b, 0x07, 0x08],
  [0x1f, 0x8b], // gzip
  [0x7f, 0x45, 0x4c, 0x46], // ELF
  [0x52, 0x61, 0x72, 0x21], // RAR
  [0x37, 0x7a, 0xbc, 0xaf], // 7z
  [0xd0, 0xcf, 0x11, 0xe0], // OLE compound document
  [0x52, 0x49, 0x46, 0x46], // RIFF media containers
];

function hasBinarySignature(bytes: Uint8Array): boolean {
  return BINARY_SIGNATURES.some((signature) =>
    signature.every((byte, index) => bytes[index] === byte),
  );
}

function validFileName(
  fileName: string,
): TaskAttachmentValidationReason | null {
  const length = Array.from(fileName).length;
  if (
    length < 1 ||
    length > 120 ||
    containsControlCharacters(fileName, false) ||
    fileName.includes("/") ||
    fileName.includes("\\") ||
    fileName === "." ||
    fileName === ".."
  ) {
    return "name";
  }
  if (!/\.(txt|md)$/iu.test(fileName)) return "extension";
  return null;
}

export function validateTaskAttachmentPayload(
  fileName: string,
  bytes: Uint8Array,
): TaskAttachmentValidation {
  const nameError = validFileName(fileName);
  if (nameError) return { ok: false, reason: nameError };
  if (bytes.byteLength === 0) return { ok: false, reason: "empty" };
  if (bytes.byteLength > MAX_ATTACHMENT_BYTES) {
    return { ok: false, reason: "size" };
  }
  if (hasBinarySignature(bytes)) return { ok: false, reason: "binary" };

  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return { ok: false, reason: "encoding" };
  }
  if (containsControlCharacters(text, true)) {
    return { ok: false, reason: "binary" };
  }

  return {
    ok: true,
    fileName,
    sizeBytes: bytes.byteLength,
    sha256: createHash("sha256").update(bytes).digest("hex"),
  };
}
