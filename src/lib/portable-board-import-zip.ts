import { createHash } from "node:crypto";
import { type FileHandle, open } from "node:fs/promises";
import { z } from "zod/v4";
import {
  MAX_PORTABLE_BOARD_CENTRAL_DIRECTORY_BYTES,
  MAX_PORTABLE_BOARD_IMPORT_BYTES,
  MAX_PORTABLE_BOARD_MANIFEST_BYTES,
  MAX_PORTABLE_BOARD_PACKAGE_ENTRIES,
} from "./portable-board-import-limits.ts";

export { MAX_PORTABLE_BOARD_IMPORT_BYTES } from "./portable-board-import-limits.ts";

const ZIP64_LOCATOR = 0x07064b50;
const ZIP64_END = 0x06064b50;
const CENTRAL_FILE = 0x02014b50;
const LOCAL_FILE = 0x04034b50;
const DATA_DESCRIPTOR = 0x08074b50;
const ZIP64_EXTRA = 0x0001;
const UTF8_AND_DESCRIPTOR_FLAGS = 0x0808;
const STORE_METHOD = 0;
const READ_CHUNK_BYTES = 64 * 1024;

const entityFiles = {
  "data/board.json": "application/json",
  "data/columns.ndjson": "application/x-ndjson",
  "data/tasks.ndjson": "application/x-ndjson",
  "data/comments.ndjson": "application/x-ndjson",
  "data/labels.ndjson": "application/x-ndjson",
  "data/task-labels.ndjson": "application/x-ndjson",
  "data/birthdays.ndjson": "application/x-ndjson",
  "data/birthday-labels.ndjson": "application/x-ndjson",
  "data/repetitions.ndjson": "application/x-ndjson",
  "data/repetition-labels.ndjson": "application/x-ndjson",
  "data/repetition-occurrences.ndjson": "application/x-ndjson",
  "data/activity.ndjson": "application/x-ndjson",
  "data/attachments.ndjson": "application/x-ndjson",
} as const;

const manifestFileSchema = z
  .object({
    path: z.string().min(1).max(65535),
    content_type: z.string().min(1).max(100),
    size_bytes: z.number().int().safe().nonnegative(),
    sha256: z.string().regex(/^[0-9a-f]{64}$/u),
    records: z.number().int().safe().nonnegative().nullable(),
  })
  .strict();

const manifestSchema = z
  .object({
    format: z.literal("openkanban-board"),
    version: z.literal(2),
    exported_at: z.string().min(1).max(100),
    schema_version: z.number().int().safe().positive(),
    calendar: z.object({ time_zone: z.string().min(1).max(100) }).strict(),
    normalization_version: z.literal(1),
    identifiers: z
      .object({ scope: z.literal("package"), grant_access: z.literal(false) })
      .strict(),
    compression: z.literal("store"),
    integrity: z.literal("sha256"),
    files: z.array(manifestFileSchema).min(Object.keys(entityFiles).length),
  })
  .strict();

export type PortableBoardImportManifest = z.infer<typeof manifestSchema>;

interface ZipEntry {
  path: string;
  size: number;
  crc32: number;
  localOffset: number;
  dataOffset: number;
  descriptorOffset: number;
}

export interface PortableBoardImportZip {
  manifest: PortableBoardImportManifest;
  entries: ReadonlyMap<string, ZipEntry>;
  readVerified(path: string): AsyncGenerator<Uint8Array>;
  close(): Promise<void>;
}

function invalid(message = "El paquete ZIP no es válido."): Error {
  return new Error(message);
}

function readU16(bytes: Uint8Array, offset: number): number {
  return new DataView(
    bytes.buffer,
    bytes.byteOffset,
    bytes.byteLength,
  ).getUint16(offset, true);
}

function readU32(bytes: Uint8Array, offset: number): number {
  return new DataView(
    bytes.buffer,
    bytes.byteOffset,
    bytes.byteLength,
  ).getUint32(offset, true);
}

function readU64(bytes: Uint8Array, offset: number): bigint {
  return new DataView(
    bytes.buffer,
    bytes.byteOffset,
    bytes.byteLength,
  ).getBigUint64(offset, true);
}

async function readAt(
  handle: FileHandle,
  offset: number,
  length: number,
): Promise<Uint8Array> {
  if (
    !Number.isSafeInteger(offset) ||
    !Number.isSafeInteger(length) ||
    offset < 0 ||
    length < 0
  ) {
    throw invalid();
  }
  const bytes = new Uint8Array(length);
  let received = 0;
  while (received < length) {
    const result = await handle.read(
      bytes,
      received,
      length - received,
      offset + received,
    );
    if (result.bytesRead === 0) throw invalid();
    received += result.bytesRead;
  }
  return bytes;
}

async function* readRange(
  handle: FileHandle,
  offset: number,
  length: number,
): AsyncGenerator<Uint8Array> {
  let read = 0;
  while (read < length) {
    const nextLength = Math.min(READ_CHUNK_BYTES, length - read);
    yield await readAt(handle, offset + read, nextLength);
    read += nextLength;
  }
}

function safeZipPath(path: string): boolean {
  if (
    path.length === 0 ||
    path.startsWith("/") ||
    path.includes("\\") ||
    path.includes(":") ||
    path.includes("\0") ||
    path.normalize("NFC") !== path
  ) {
    return false;
  }
  const segments = path.split("/");
  return segments.every(
    (segment) =>
      segment !== "" &&
      segment !== "." &&
      segment !== ".." &&
      !hasControlCharacters(segment),
  );
}

function hasControlCharacters(value: string): boolean {
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0;
    if (codePoint <= 0x1f || (codePoint >= 0x7f && codePoint <= 0x9f)) {
      return true;
    }
  }
  return false;
}

function parseZip64Extra(extra: Uint8Array): {
  size: bigint;
  compressedSize: bigint;
  localOffset: bigint;
} {
  if (
    extra.byteLength !== 28 ||
    readU16(extra, 0) !== ZIP64_EXTRA ||
    readU16(extra, 2) !== 24
  ) {
    throw invalid();
  }
  return {
    size: readU64(extra, 4),
    compressedSize: readU64(extra, 12),
    localOffset: readU64(extra, 20),
  };
}

async function findCentralDirectory(
  handle: FileHandle,
  fileSize: number,
): Promise<{ offset: number; size: number; count: number }> {
  const tailLength = Math.min(fileSize, 65_557 + 76);
  const tailOffset = fileSize - tailLength;
  const tail = await readAt(handle, tailOffset, tailLength);
  let endOffset = -1;
  for (let offset = tail.byteLength - 22; offset >= 0; offset -= 1) {
    if (readU32(tail, offset) === 0x06054b50) {
      endOffset = offset;
      break;
    }
  }
  if (endOffset < 0 || endOffset + 22 !== tail.byteLength) throw invalid();
  const end = tail.subarray(endOffset);
  if (
    readU16(end, 4) !== 0 ||
    readU16(end, 6) !== 0 ||
    readU16(end, 8) !== 0xffff ||
    readU16(end, 10) !== 0xffff ||
    readU32(end, 12) !== 0xffff_ffff ||
    readU32(end, 16) !== 0xffff_ffff ||
    readU16(end, 20) !== 0
  ) {
    throw invalid();
  }

  const locatorOffset = endOffset - 20;
  if (locatorOffset < 0 || readU32(tail, locatorOffset) !== ZIP64_LOCATOR) {
    throw invalid();
  }
  const locator = tail.subarray(locatorOffset, locatorOffset + 20);
  if (readU32(locator, 4) !== 0 || readU32(locator, 16) !== 1) throw invalid();
  const zip64EndBig = readU64(locator, 8);
  if (zip64EndBig > BigInt(Number.MAX_SAFE_INTEGER)) throw invalid();
  const zip64EndOffset = Number(zip64EndBig);
  if (zip64EndOffset + 56 !== tailOffset + locatorOffset) throw invalid();
  const zip64End = await readAt(handle, zip64EndOffset, 56);
  if (
    readU32(zip64End, 0) !== ZIP64_END ||
    readU64(zip64End, 4) !== BigInt(44) ||
    readU32(zip64End, 16) !== 0 ||
    readU32(zip64End, 20) !== 0 ||
    readU64(zip64End, 24) !== readU64(zip64End, 32)
  ) {
    throw invalid();
  }
  const countBig = readU64(zip64End, 32);
  const sizeBig = readU64(zip64End, 40);
  const offsetBig = readU64(zip64End, 48);
  if (
    countBig < BigInt(Object.keys(entityFiles).length + 1) ||
    countBig > BigInt(MAX_PORTABLE_BOARD_PACKAGE_ENTRIES) ||
    sizeBig > BigInt(MAX_PORTABLE_BOARD_CENTRAL_DIRECTORY_BYTES) ||
    offsetBig > BigInt(Number.MAX_SAFE_INTEGER) ||
    sizeBig > BigInt(Number.MAX_SAFE_INTEGER)
  ) {
    throw invalid();
  }
  const offset = Number(offsetBig);
  const size = Number(sizeBig);
  const count = Number(countBig);
  if (
    offset + size !== zip64EndOffset ||
    offset + size > fileSize ||
    size < count * 46
  ) {
    throw invalid();
  }
  return { offset, size, count };
}

async function readCentralEntries(
  handle: FileHandle,
  fileSize: number,
  directory: { offset: number; size: number; count: number },
): Promise<Map<string, ZipEntry>> {
  const entries = new Map<string, ZipEntry>();
  let cursor = directory.offset;
  const end = directory.offset + directory.size;
  const encoder = new TextDecoder("utf-8", { fatal: true });
  const pathKeys = new Set<string>();

  for (let index = 0; index < directory.count; index += 1) {
    const fixed = await readAt(handle, cursor, 46);
    if (readU32(fixed, 0) !== CENTRAL_FILE) throw invalid();
    const flags = readU16(fixed, 8);
    const method = readU16(fixed, 10);
    const crc32 = readU32(fixed, 16);
    const compressed32 = readU32(fixed, 20);
    const size32 = readU32(fixed, 24);
    const nameLength = readU16(fixed, 28);
    const extraLength = readU16(fixed, 30);
    const commentLength = readU16(fixed, 32);
    const diskStart = readU16(fixed, 34);
    const externalAttributes = readU32(fixed, 38);
    const offset32 = readU32(fixed, 42);
    if (
      flags !== UTF8_AND_DESCRIPTOR_FLAGS ||
      method !== STORE_METHOD ||
      compressed32 !== 0xffff_ffff ||
      size32 !== 0xffff_ffff ||
      offset32 !== 0xffff_ffff ||
      diskStart !== 0 ||
      commentLength !== 0
    ) {
      throw invalid();
    }
    const variable = await readAt(
      handle,
      cursor + 46,
      nameLength + extraLength,
    );
    const encodedName = variable.subarray(0, nameLength);
    const name = encoder.decode(encodedName);
    if (!safeZipPath(name))
      throw invalid("El paquete contiene una ruta insegura.");
    const normalized = name.toLocaleLowerCase("en-US");
    if (pathKeys.has(normalized))
      throw invalid("El paquete contiene rutas duplicadas.");
    pathKeys.add(normalized);
    const unixMode = externalAttributes >>> 16;
    if ((unixMode & 0xf000) === 0xa000 || (unixMode & 0xf000) === 0x4000) {
      throw invalid("El paquete contiene una entrada de tipo no permitido.");
    }
    const sizes = parseZip64Extra(variable.subarray(nameLength));
    if (
      sizes.size !== sizes.compressedSize ||
      sizes.size > BigInt(Number.MAX_SAFE_INTEGER) ||
      sizes.localOffset > BigInt(Number.MAX_SAFE_INTEGER)
    ) {
      throw invalid();
    }
    const size = Number(sizes.size);
    const localOffset = Number(sizes.localOffset);
    if (localOffset >= directory.offset || localOffset + 30 > fileSize)
      throw invalid();
    const dataOffset = localOffset + 30;
    entries.set(name, {
      path: name,
      size,
      crc32,
      localOffset,
      dataOffset,
      descriptorOffset: dataOffset + size,
    });
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  if (cursor !== end) throw invalid();

  const byOffset = [...entries.values()].sort(
    (left, right) => left.localOffset - right.localOffset,
  );
  let expectedOffset = 0;
  for (const entry of byOffset) {
    const local = await readAt(handle, entry.localOffset, 30);
    if (
      readU32(local, 0) !== LOCAL_FILE ||
      readU16(local, 4) !== 45 ||
      readU16(local, 6) !== UTF8_AND_DESCRIPTOR_FLAGS ||
      readU16(local, 8) !== STORE_METHOD ||
      readU32(local, 18) !== 0xffff_ffff ||
      readU32(local, 22) !== 0xffff_ffff
    ) {
      throw invalid();
    }
    const localNameLength = readU16(local, 26);
    const localExtraLength = readU16(local, 28);
    const localVariable = await readAt(
      handle,
      entry.localOffset + 30,
      localNameLength + localExtraLength,
    );
    const localName = new TextDecoder("utf-8", { fatal: true }).decode(
      localVariable.subarray(0, localNameLength),
    );
    if (
      localName !== entry.path ||
      localExtraLength !== 20 ||
      localVariable.byteLength !== localNameLength + 20 ||
      readU16(localVariable, localNameLength) !== ZIP64_EXTRA ||
      readU16(localVariable, localNameLength + 2) !== 16 ||
      readU64(localVariable, localNameLength + 4) !== BigInt(0) ||
      readU64(localVariable, localNameLength + 12) !== BigInt(0)
    ) {
      throw invalid();
    }
    entry.dataOffset =
      entry.localOffset + 30 + localNameLength + localExtraLength;
    entry.descriptorOffset = entry.dataOffset + entry.size;
    const descriptor = await readAt(handle, entry.descriptorOffset, 24);
    if (
      readU32(descriptor, 0) !== DATA_DESCRIPTOR ||
      readU32(descriptor, 4) !== entry.crc32 ||
      readU64(descriptor, 8) !== BigInt(entry.size) ||
      readU64(descriptor, 16) !== BigInt(entry.size)
    ) {
      throw invalid();
    }
    if (entry.localOffset !== expectedOffset) throw invalid();
    expectedOffset = entry.descriptorOffset + 24;
  }
  if (expectedOffset !== directory.offset) throw invalid();
  return entries;
}

function validateManifest(
  value: unknown,
  entries: ReadonlyMap<string, ZipEntry>,
): PortableBoardImportManifest {
  const parsed = manifestSchema.parse(value);
  if (
    !Number.isFinite(Date.parse(parsed.exported_at)) ||
    parsed.files.length !== entries.size - 1
  ) {
    throw invalid("El manifiesto no coincide con el contenido del paquete.");
  }
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: parsed.calendar.time_zone });
  } catch {
    throw invalid("La zona horaria del respaldo no es válida.");
  }

  const files = new Map<string, (typeof parsed.files)[number]>();
  for (const file of parsed.files) {
    if (
      !safeZipPath(file.path) ||
      file.path === "manifest.json" ||
      files.has(file.path)
    ) {
      throw invalid("El manifiesto contiene rutas repetidas o inseguras.");
    }
    const entityContentType =
      entityFiles[file.path as keyof typeof entityFiles];
    const isObject = /^objects\/attachment_[0-9a-f]{64}\.(?:txt|md)$/iu.test(
      file.path,
    );
    if (
      (!entityContentType && !isObject) ||
      (entityContentType && file.content_type !== entityContentType) ||
      (isObject && file.content_type !== "text/plain; charset=utf-8") ||
      (file.path === "data/board.json" && file.records !== 1) ||
      (file.path.endsWith(".ndjson") && file.records === null)
    ) {
      throw invalid("El manifiesto declara un archivo no compatible.");
    }
    const entry = entries.get(file.path);
    if (!entry || entry.size !== file.size_bytes) {
      throw invalid("El tamaño declarado no coincide con el paquete.");
    }
    files.set(file.path, file);
  }
  if (
    files.size !== entries.size - 1 ||
    entries.has("manifest.json") === false
  ) {
    throw invalid("El paquete no contiene todos los archivos declarados.");
  }
  for (const path of Object.keys(entityFiles)) {
    if (!files.has(path))
      throw invalid("El paquete no contiene todas las entidades requeridas.");
  }
  for (const path of entries.keys()) {
    if (path !== "manifest.json" && !files.has(path)) {
      throw invalid(
        "El paquete incluye archivos que no aparecen en el manifiesto.",
      );
    }
  }
  return parsed;
}

export async function openPortableBoardImportZip(
  filePath: string,
): Promise<PortableBoardImportZip> {
  const handle = await open(filePath, "r");
  try {
    const stat = await handle.stat();
    if (
      !stat.isFile() ||
      stat.size < 100 ||
      stat.size > MAX_PORTABLE_BOARD_IMPORT_BYTES
    ) {
      throw invalid("El paquete supera el límite técnico permitido.");
    }
    const directory = await findCentralDirectory(handle, stat.size);
    const entries = await readCentralEntries(handle, stat.size, directory);
    const manifestEntry = entries.get("manifest.json");
    if (
      !manifestEntry ||
      manifestEntry.size > MAX_PORTABLE_BOARD_MANIFEST_BYTES
    )
      throw invalid();
    const manifestBytes = await readAt(
      handle,
      manifestEntry.dataOffset,
      manifestEntry.size,
    );
    if (crc32(manifestBytes) !== manifestEntry.crc32) throw invalid();
    let manifestValue: unknown;
    try {
      manifestValue = JSON.parse(
        new TextDecoder("utf-8", { fatal: true }).decode(manifestBytes),
      );
    } catch {
      throw invalid("El manifiesto no contiene JSON UTF-8 válido.");
    }
    const manifest = validateManifest(manifestValue, entries);
    const manifestFiles = new Map(
      manifest.files.map((file) => [file.path, file]),
    );

    return {
      manifest,
      entries,
      async *readVerified(path: string): AsyncGenerator<Uint8Array> {
        const entry = entries.get(path);
        const metadata = manifestFiles.get(path);
        if (!entry || !metadata || path === "manifest.json") throw invalid();
        const digest = createHash("sha256");
        let checksum = 0xffff_ffff;
        let size = 0;
        for await (const chunk of readRange(
          handle,
          entry.dataOffset,
          entry.size,
        )) {
          digest.update(chunk);
          checksum = updateCrc32(checksum, chunk);
          size += chunk.byteLength;
          yield chunk;
        }
        checksum = (checksum ^ 0xffff_ffff) >>> 0;
        if (
          size !== metadata.size_bytes ||
          checksum !== entry.crc32 ||
          digest.digest("hex") !== metadata.sha256
        ) {
          throw invalid("El tamaño o hash de un archivo no coincide.");
        }
      },
      close: () => handle.close(),
    };
  } catch (error) {
    await handle.close();
    throw error;
  }
}

function crc32(bytes: Uint8Array): number {
  return (updateCrc32(0xffff_ffff, bytes) ^ 0xffff_ffff) >>> 0;
}

function updateCrc32(current: number, bytes: Uint8Array): number {
  let crc = current;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc & 1) !== 0 ? 0xedb8_8320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return crc >>> 0;
}
