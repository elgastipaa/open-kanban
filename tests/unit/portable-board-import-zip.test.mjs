import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { openPortableBoardImportZip } from "../../src/lib/portable-board-import-zip.ts";
import { createPortableZipStream } from "../../src/lib/portable-export-zip.ts";

async function collect(stream) {
  const chunks = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
}

const metadata = {
  exportedAt: "2026-11-02T12:00:00.000Z",
  schemaVersion: 68,
  timeZone: "America/Argentina/Buenos_Aires",
  normalizationVersion: 1,
};

const records = {
  "data/board.json": [
    {
      id: `board_${"a".repeat(64)}`,
      name: "Fixture board",
      time_zone: metadata.timeZone,
      created_at: metadata.exportedAt,
      updated_at: metadata.exportedAt,
    },
  ],
  "data/columns.ndjson": [],
  "data/tasks.ndjson": [],
  "data/comments.ndjson": [],
  "data/labels.ndjson": [],
  "data/task-labels.ndjson": [],
  "data/birthdays.ndjson": [],
  "data/birthday-labels.ndjson": [],
  "data/repetitions.ndjson": [],
  "data/repetition-labels.ndjson": [],
  "data/repetition-occurrences.ndjson": [],
  "data/activity.ndjson": [],
  "data/attachments.ndjson": [],
};

function entitySources() {
  return Object.entries(records).map(([name, rows]) => {
    const content = Buffer.from(
      name.endsWith(".json")
        ? `${JSON.stringify(rows[0])}\n`
        : rows.map((row) => `${JSON.stringify(row)}\n`).join(""),
    );
    return {
      name,
      contentType: name.endsWith(".json")
        ? "application/json"
        : "application/x-ndjson",
      recordCount: rows.length,
      expectedSize: content.byteLength,
      expectedSha256: createHash("sha256").update(content).digest("hex"),
      chunks: (async function* () {
        for (let offset = 0; offset < content.byteLength; offset += 7) {
          yield content.subarray(offset, offset + 7);
        }
      })(),
    };
  });
}

async function writeArchive(sources) {
  const folder = await mkdtemp(join(tmpdir(), "openkanban-v2-import-"));
  const path = join(folder, "backup.zip");
  const bytes = await collect(createPortableZipStream(sources, metadata));
  await writeFile(path, bytes);
  return { folder, path, bytes };
}

test("v2 import reads ZIP STORE entries incrementally and verifies manifest hashes", async () => {
  const archive = await writeArchive(
    (async function* () {
      yield* entitySources();
    })(),
  );
  try {
    const imported = await openPortableBoardImportZip(archive.path);
    try {
      assert.equal(imported.manifest.version, 2);
      assert.equal(imported.manifest.schema_version, 68);
      assert.equal(imported.manifest.calendar.time_zone, metadata.timeZone);
      assert.equal(imported.entries.size, Object.keys(records).length + 1);
      const chunks = [];
      for await (const chunk of imported.readVerified("data/board.json")) {
        chunks.push(Buffer.from(chunk));
      }
      assert.deepEqual(
        Buffer.concat(chunks),
        Buffer.from(`${JSON.stringify(records["data/board.json"][0])}\n`),
      );
    } finally {
      await imported.close();
    }
  } finally {
    await rm(archive.folder, { recursive: true, force: true });
  }
});

test("v2 import rejects duplicate, traversal, symlink and compressed ZIP entries", async () => {
  const archive = await writeArchive(
    (async function* () {
      yield* entitySources();
    })(),
  );
  try {
    const original = await readFile(archive.path);
    const centralDirectory = original.lastIndexOf(
      Buffer.from([0x50, 0x4b, 0x01, 0x02]),
    );
    assert.ok(centralDirectory >= 0);
    const nameLength = original.readUInt16LE(centralDirectory + 28);
    const nameOffset = centralDirectory + 46;
    const originalName = original.toString(
      "utf8",
      nameOffset,
      nameOffset + nameLength,
    );
    const variants = [
      (bytes) => bytes.fill(0x61, nameOffset, nameOffset + nameLength),
      (bytes) => bytes.fill(0x2e, nameOffset, nameOffset + nameLength),
      (bytes) =>
        bytes.writeUInt32LE((0o120777 << 16) >>> 0, centralDirectory + 38),
      (bytes) => bytes.writeUInt16LE(8, centralDirectory + 10),
    ];
    assert.ok(originalName.length > 0);
    for (const mutate of variants) {
      const corrupted = Buffer.from(original);
      mutate(corrupted);
      await writeFile(archive.path, corrupted);
      await assert.rejects(openPortableBoardImportZip(archive.path));
    }
  } finally {
    await rm(archive.folder, { recursive: true, force: true });
  }
});
