import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import {
  MAX_PORTABLE_BOARD_IMPORT_BYTES,
  MAX_PORTABLE_BOARD_PACKAGE_ENTRIES,
  MAX_PORTABLE_BOARD_RECORDS,
} from "../../src/lib/portable-board-import-limits.ts";
import { createPortableZipStream } from "../../src/lib/portable-export-zip.ts";

async function collect(stream) {
  const chunks = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
}

function zip64Entries(archive) {
  const entries = new Map();
  let cursor = archive.lastIndexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
  const headers = [];
  while (cursor >= 0) {
    headers.push(cursor);
    cursor = archive.lastIndexOf(
      Buffer.from([0x50, 0x4b, 0x01, 0x02]),
      cursor - 1,
    );
  }

  for (const header of headers.reverse()) {
    const nameLength = archive.readUInt16LE(header + 28);
    const extraLength = archive.readUInt16LE(header + 30);
    const name = archive.toString(
      "utf8",
      header + 46,
      header + 46 + nameLength,
    );
    const extraStart = header + 46 + nameLength;
    let extraCursor = extraStart;
    let size = null;
    let localOffset = null;
    while (extraCursor < extraStart + extraLength) {
      const id = archive.readUInt16LE(extraCursor);
      const length = archive.readUInt16LE(extraCursor + 2);
      if (id === 0x0001) {
        size = archive.readBigUInt64LE(extraCursor + 4);
        localOffset = archive.readBigUInt64LE(extraCursor + 20);
      }
      extraCursor += 4 + length;
    }
    assert.notEqual(size, null, `ZIP64 size for ${name}`);
    assert.notEqual(localOffset, null, `ZIP64 offset for ${name}`);
    const local = Number(localOffset);
    const localNameLength = archive.readUInt16LE(local + 26);
    const localExtraLength = archive.readUInt16LE(local + 28);
    const start = local + 30 + localNameLength + localExtraLength;
    entries.set(name, archive.subarray(start, start + Number(size)));
  }

  return entries;
}

const metadata = {
  exportedAt: "2026-11-02T12:00:00.000Z",
  schemaVersion: 68,
  timeZone: "America/Argentina/Buenos_Aires",
  normalizationVersion: 1,
};

test("export v2 streams ZIP STORE entries with a manifest of verified sizes and hashes", async () => {
  const entityBytes = Buffer.from('{"id":"task-1","title":"Síntesis"}\n');
  const objectBytes = Buffer.from("texto adjunto\n");
  const archive = await collect(
    createPortableZipStream(
      (async function* () {
        yield {
          name: "data/tasks.ndjson",
          contentType: "application/x-ndjson",
          recordCount: 1,
          chunks: (async function* () {
            yield entityBytes.subarray(0, 8);
            yield entityBytes.subarray(8);
          })(),
        };
        yield {
          name: "objects/attachment-1",
          contentType: "text/plain",
          expectedSize: objectBytes.byteLength,
          expectedSha256: createHash("sha256")
            .update(objectBytes)
            .digest("hex"),
          chunks: (async function* () {
            yield objectBytes;
          })(),
        };
      })(),
      metadata,
    ),
  );

  const entries = zip64Entries(archive);
  assert.deepEqual(entries.get("data/tasks.ndjson"), entityBytes);
  assert.deepEqual(entries.get("objects/attachment-1"), objectBytes);
  assert.ok(entries.has("manifest.json"));
  assert.ok(archive.includes(Buffer.from([0x50, 0x4b, 0x06, 0x06])));

  const manifest = JSON.parse(entries.get("manifest.json").toString("utf8"));
  assert.equal(manifest.format, "openkanban-board");
  assert.equal(manifest.version, 2);
  assert.equal(manifest.schema_version, 68);
  assert.equal(manifest.calendar.time_zone, metadata.timeZone);
  assert.deepEqual(
    manifest.files.map(({ path, size_bytes, sha256, records }) => ({
      path,
      size_bytes,
      sha256,
      records,
    })),
    [
      {
        path: "data/tasks.ndjson",
        size_bytes: entityBytes.byteLength,
        sha256: createHash("sha256").update(entityBytes).digest("hex"),
        records: 1,
      },
      {
        path: "objects/attachment-1",
        size_bytes: objectBytes.byteLength,
        sha256: createHash("sha256").update(objectBytes).digest("hex"),
        records: null,
      },
    ],
  );
});

test("export v2 rejects unsafe package paths and does not finish a truncated archive", async () => {
  await assert.rejects(
    collect(
      createPortableZipStream(
        (async function* () {
          yield {
            name: "../outside.txt",
            contentType: "text/plain",
            chunks: (async function* () {
              yield Buffer.from("unsafe");
            })(),
          };
        })(),
        metadata,
      ),
    ),
    /ruta/i,
  );

  const partial = [];
  const stream = createPortableZipStream(
    (async function* () {
      yield {
        name: "objects/attachment-2",
        contentType: "text/plain",
        expectedSize: 20,
        expectedSha256: "0".repeat(64),
        chunks: (async function* () {
          yield Buffer.from("truncated");
        })(),
      };
    })(),
    metadata,
  );
  await assert.rejects(async () => {
    for await (const chunk of stream) partial.push(Buffer.from(chunk));
  }, /integridad|tamaño|hash/i);
  const bytes = Buffer.concat(partial);
  assert.equal(bytes.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06])), -1);
});

test("export v2 shares bounded package, entry, and record budgets with import", async () => {
  await assert.rejects(
    collect(
      createPortableZipStream(
        (async function* () {
          yield {
            name: "data/tasks.ndjson",
            contentType: "application/x-ndjson",
            recordCount: MAX_PORTABLE_BOARD_RECORDS + 1,
            chunks: (async function* () {})(),
          };
        })(),
        metadata,
      ),
    ),
    /registros/i,
  );
  await assert.rejects(
    collect(
      createPortableZipStream(
        (async function* () {
          yield {
            name: "objects/too-large.txt",
            contentType: "text/plain",
            expectedSize: MAX_PORTABLE_BOARD_IMPORT_BYTES + 1,
            chunks: (async function* () {})(),
          };
        })(),
        metadata,
      ),
    ),
    /presupuesto/i,
  );
  await assert.rejects(async () => {
    for await (const _chunk of createPortableZipStream(
      (async function* () {
        for (
          let index = 0;
          index < MAX_PORTABLE_BOARD_PACKAGE_ENTRIES;
          index += 1
        ) {
          yield {
            name: `objects/${index}`,
            contentType: "text/plain",
            chunks: (async function* () {})(),
          };
        }
      })(),
      metadata,
    )) {
      // Discard prior bounded chunks; the export must reject before writing entry 25,000.
    }
  }, /rutas/i);
});
