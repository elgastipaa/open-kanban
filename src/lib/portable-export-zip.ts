import { createHash } from "node:crypto";

const UTF8_FLAG = 0x0800;
const DATA_DESCRIPTOR_FLAG = 0x0008;
const ZIP64_SENTINEL = 0xffff_ffff;
const CRC32_TABLE = createCrc32Table();

export interface PortableZipSource {
  name: string;
  contentType: string;
  chunks: AsyncIterable<Uint8Array>;
  recordCount?: number;
  expectedSize?: number;
  expectedSha256?: string;
}

export interface PortableExportMetadata {
  exportedAt: string;
  schemaVersion: number;
  timeZone: string;
  normalizationVersion: number;
}

interface ExportedFile {
  path: string;
  content_type: string;
  size_bytes: number;
  sha256: string;
  records: number | null;
}

interface CentralDirectoryEntry {
  name: Uint8Array;
  crc32: number;
  size: bigint;
  localOffset: bigint;
  dosTime: number;
  dosDate: number;
}

export async function* createPortableZipStream(
  sources: AsyncIterable<PortableZipSource>,
  metadata: PortableExportMetadata,
): AsyncGenerator<Uint8Array> {
  validateMetadata(metadata);

  let offset = BigInt(0);
  const names = new Set<string>();
  const files: ExportedFile[] = [];
  const centralDirectory: CentralDirectoryEntry[] = [];
  const timestamp = dosTimestamp(metadata.exportedAt);

  for await (const source of sources) {
    const canonicalName = validateEntry(source, names);
    const encodedName = new TextEncoder().encode(source.name);
    const localOffset = offset;
    const localHeader = makeLocalHeader(
      encodedName,
      timestamp.dosTime,
      timestamp.dosDate,
    );
    offset += BigInt(localHeader.byteLength);
    yield localHeader;

    const digest = createHash("sha256");
    let crc = 0xffff_ffff;
    let size = BigInt(0);
    for await (const chunk of source.chunks) {
      if (!(chunk instanceof Uint8Array)) {
        throw new Error(
          "El contenido exportado no es una secuencia de bytes válida.",
        );
      }
      if (chunk.byteLength === 0) continue;
      digest.update(chunk);
      crc = updateCrc32(crc, chunk);
      size += BigInt(chunk.byteLength);
      offset += BigInt(chunk.byteLength);
      yield chunk;
    }

    crc = (crc ^ 0xffff_ffff) >>> 0;
    const sha256 = digest.digest("hex");
    if (
      source.expectedSize !== undefined &&
      size !== BigInt(source.expectedSize)
    ) {
      throw new Error(
        `El tamaño de ${source.name} no coincide con la instantánea.`,
      );
    }
    if (
      source.expectedSha256 !== undefined &&
      sha256 !== source.expectedSha256.toLowerCase()
    ) {
      throw new Error(
        `La integridad de ${source.name} no coincide con la instantánea.`,
      );
    }

    const dataDescriptor = makeDataDescriptor(crc, size);
    offset += BigInt(dataDescriptor.byteLength);
    yield dataDescriptor;

    const sizeNumber = Number(size);
    if (!Number.isSafeInteger(sizeNumber)) {
      throw new Error(
        "El tamaño de un archivo supera el rango admitido por el manifiesto.",
      );
    }
    files.push({
      path: canonicalName,
      content_type: source.contentType,
      size_bytes: sizeNumber,
      sha256,
      records: source.recordCount ?? null,
    });
    centralDirectory.push({
      name: encodedName,
      crc32: crc,
      size,
      localOffset,
      dosTime: timestamp.dosTime,
      dosDate: timestamp.dosDate,
    });
  }

  const manifest = makeManifest(metadata, files);
  const manifestBytes = new TextEncoder().encode(
    `${JSON.stringify(manifest)}\n`,
  );
  const manifestEntry: PortableZipSource = {
    name: "manifest.json",
    contentType: "application/json",
    expectedSize: manifestBytes.byteLength,
    chunks: (async function* () {
      yield manifestBytes;
    })(),
  };
  validateEntry(manifestEntry, names);
  const manifestName = new TextEncoder().encode(manifestEntry.name);
  const manifestOffset = offset;
  const manifestHeader = makeLocalHeader(
    manifestName,
    timestamp.dosTime,
    timestamp.dosDate,
  );
  offset += BigInt(manifestHeader.byteLength);
  yield manifestHeader;
  offset += BigInt(manifestBytes.byteLength);
  yield manifestBytes;
  const manifestCrc = crc32(manifestBytes);
  const manifestDescriptor = makeDataDescriptor(
    manifestCrc,
    BigInt(manifestBytes.byteLength),
  );
  offset += BigInt(manifestDescriptor.byteLength);
  yield manifestDescriptor;
  centralDirectory.push({
    name: manifestName,
    crc32: manifestCrc,
    size: BigInt(manifestBytes.byteLength),
    localOffset: manifestOffset,
    dosTime: timestamp.dosTime,
    dosDate: timestamp.dosDate,
  });

  const centralDirectoryStart = offset;
  for (const entry of centralDirectory) {
    const header = makeCentralDirectoryHeader(entry);
    offset += BigInt(header.byteLength);
    yield header;
  }
  const centralDirectorySize = offset - centralDirectoryStart;
  const zip64EndOffset = offset;
  const zip64End = makeZip64EndRecord(
    BigInt(centralDirectory.length),
    centralDirectorySize,
    centralDirectoryStart,
  );
  offset += BigInt(zip64End.byteLength);
  yield zip64End;
  const locator = makeZip64Locator(zip64EndOffset);
  offset += BigInt(locator.byteLength);
  yield locator;
  const end = makeEndRecord();
  offset += BigInt(end.byteLength);
  yield end;
}

function validateMetadata(metadata: PortableExportMetadata): void {
  if (
    !Number.isSafeInteger(metadata.schemaVersion) ||
    metadata.schemaVersion < 1 ||
    !Number.isSafeInteger(metadata.normalizationVersion) ||
    metadata.normalizationVersion < 1 ||
    !Number.isFinite(Date.parse(metadata.exportedAt)) ||
    !metadata.timeZone
  ) {
    throw new Error("Los metadatos de exportación no son válidos.");
  }
}

function validateEntry(source: PortableZipSource, names: Set<string>): string {
  if (
    typeof source.name !== "string" ||
    source.name.length === 0 ||
    source.name.startsWith("/") ||
    source.name.includes("\\") ||
    source.name.includes("\0") ||
    new TextEncoder().encode(source.name).byteLength > 0xffff ||
    source.name
      .split("/")
      .some((part) => part === "" || part === "." || part === "..")
  ) {
    throw new Error("La ruta del paquete no es segura.");
  }
  const normalizedName = source.name.toLocaleLowerCase("en-US");
  if (names.has(normalizedName)) {
    throw new Error("El paquete contiene una ruta duplicada.");
  }
  if (
    !source.contentType ||
    !source.chunks ||
    typeof source.chunks[Symbol.asyncIterator] !== "function" ||
    /[\r\n]/u.test(source.contentType) ||
    (source.recordCount !== undefined &&
      (!Number.isSafeInteger(source.recordCount) || source.recordCount < 0)) ||
    (source.expectedSize !== undefined &&
      (!Number.isSafeInteger(source.expectedSize) ||
        source.expectedSize < 0)) ||
    (source.expectedSha256 !== undefined &&
      !/^[0-9a-f]{64}$/iu.test(source.expectedSha256))
  ) {
    throw new Error("Los datos del archivo exportado no son válidos.");
  }
  names.add(normalizedName);
  return source.name;
}

function makeManifest(
  metadata: PortableExportMetadata,
  files: ExportedFile[],
): Record<string, unknown> {
  return {
    format: "openkanban-board",
    version: 2,
    exported_at: metadata.exportedAt,
    schema_version: metadata.schemaVersion,
    calendar: { time_zone: metadata.timeZone },
    normalization_version: metadata.normalizationVersion,
    identifiers: { scope: "package", grant_access: false },
    compression: "store",
    integrity: "sha256",
    files,
  };
}

function dosTimestamp(value: string): { dosTime: number; dosDate: number } {
  const date = new Date(value);
  const year = Math.max(1980, Math.min(2107, date.getUTCFullYear()));
  const dosDate =
    ((year - 1980) << 9) | ((date.getUTCMonth() + 1) << 5) | date.getUTCDate();
  const dosTime =
    (date.getUTCHours() << 11) |
    (date.getUTCMinutes() << 5) |
    Math.floor(date.getUTCSeconds() / 2);
  return { dosTime, dosDate };
}

function makeLocalHeader(
  name: Uint8Array,
  dosTime: number,
  dosDate: number,
): Uint8Array {
  const result = new Uint8Array(30 + name.byteLength + 20);
  const view = new DataView(result.buffer);
  view.setUint32(0, 0x04034b50, true);
  view.setUint16(4, 45, true);
  view.setUint16(6, UTF8_FLAG | DATA_DESCRIPTOR_FLAG, true);
  view.setUint16(8, 0, true);
  view.setUint16(10, dosTime, true);
  view.setUint16(12, dosDate, true);
  view.setUint32(14, 0, true);
  view.setUint32(18, ZIP64_SENTINEL, true);
  view.setUint32(22, ZIP64_SENTINEL, true);
  view.setUint16(26, name.byteLength, true);
  view.setUint16(28, 20, true);
  result.set(name, 30);
  view.setUint16(30 + name.byteLength, 0x0001, true);
  view.setUint16(32 + name.byteLength, 16, true);
  view.setBigUint64(34 + name.byteLength, BigInt(0), true);
  view.setBigUint64(42 + name.byteLength, BigInt(0), true);
  return result;
}

function makeDataDescriptor(crc: number, size: bigint): Uint8Array {
  const result = new Uint8Array(24);
  const view = new DataView(result.buffer);
  view.setUint32(0, 0x08074b50, true);
  view.setUint32(4, crc, true);
  view.setBigUint64(8, size, true);
  view.setBigUint64(16, size, true);
  return result;
}

function makeCentralDirectoryHeader(entry: CentralDirectoryEntry): Uint8Array {
  const extraLength = 28;
  const result = new Uint8Array(46 + entry.name.byteLength + extraLength);
  const view = new DataView(result.buffer);
  view.setUint32(0, 0x02014b50, true);
  view.setUint16(4, 0x031e, true);
  view.setUint16(6, 45, true);
  view.setUint16(8, UTF8_FLAG | DATA_DESCRIPTOR_FLAG, true);
  view.setUint16(10, 0, true);
  view.setUint16(12, entry.dosTime, true);
  view.setUint16(14, entry.dosDate, true);
  view.setUint32(16, entry.crc32, true);
  view.setUint32(20, ZIP64_SENTINEL, true);
  view.setUint32(24, ZIP64_SENTINEL, true);
  view.setUint16(28, entry.name.byteLength, true);
  view.setUint16(30, extraLength, true);
  view.setUint16(32, 0, true);
  view.setUint16(34, 0, true);
  view.setUint16(36, 0, true);
  view.setUint32(38, 0o100644 << 16, true);
  view.setUint32(42, ZIP64_SENTINEL, true);
  result.set(entry.name, 46);
  const extra = 46 + entry.name.byteLength;
  view.setUint16(extra, 0x0001, true);
  view.setUint16(extra + 2, 24, true);
  view.setBigUint64(extra + 4, entry.size, true);
  view.setBigUint64(extra + 12, entry.size, true);
  view.setBigUint64(extra + 20, entry.localOffset, true);
  return result;
}

function makeZip64EndRecord(
  entryCount: bigint,
  centralDirectorySize: bigint,
  centralDirectoryOffset: bigint,
): Uint8Array {
  const result = new Uint8Array(56);
  const view = new DataView(result.buffer);
  view.setUint32(0, 0x06064b50, true);
  view.setBigUint64(4, BigInt(44), true);
  view.setUint16(12, 0x031e, true);
  view.setUint16(14, 45, true);
  view.setUint32(16, 0, true);
  view.setUint32(20, 0, true);
  view.setBigUint64(24, entryCount, true);
  view.setBigUint64(32, entryCount, true);
  view.setBigUint64(40, centralDirectorySize, true);
  view.setBigUint64(48, centralDirectoryOffset, true);
  return result;
}

function makeZip64Locator(zip64EndOffset: bigint): Uint8Array {
  const result = new Uint8Array(20);
  const view = new DataView(result.buffer);
  view.setUint32(0, 0x07064b50, true);
  view.setUint32(4, 0, true);
  view.setBigUint64(8, zip64EndOffset, true);
  view.setUint32(16, 1, true);
  return result;
}

function makeEndRecord(): Uint8Array {
  const result = new Uint8Array(22);
  const view = new DataView(result.buffer);
  view.setUint32(0, 0x06054b50, true);
  view.setUint16(4, 0, true);
  view.setUint16(6, 0, true);
  view.setUint16(8, 0xffff, true);
  view.setUint16(10, 0xffff, true);
  view.setUint32(12, ZIP64_SENTINEL, true);
  view.setUint32(16, ZIP64_SENTINEL, true);
  view.setUint16(20, 0, true);
  return result;
}

function crc32(bytes: Uint8Array): number {
  return (updateCrc32(0xffff_ffff, bytes) ^ 0xffff_ffff) >>> 0;
}

function updateCrc32(current: number, bytes: Uint8Array): number {
  let crc = current;
  for (const byte of bytes)
    crc = CRC32_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return crc >>> 0;
}

function createCrc32Table(): Uint32Array {
  const table = new Uint32Array(256);
  for (let index = 0; index < table.length; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) {
      value = (value & 1) !== 0 ? 0xedb8_8320 ^ (value >>> 1) : value >>> 1;
    }
    table[index] = value >>> 0;
  }
  return table;
}
