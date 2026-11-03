import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  preparePortableBoardImport,
  validatePortableBoardImportRecord,
} from "../../src/lib/portable-board-import.ts";
import { openPortableBoardImportZip } from "../../src/lib/portable-board-import-zip.ts";
import { createPortableZipStream } from "../../src/lib/portable-export-zip.ts";

const timestamp = "2026-11-02T12:00:00.000Z";
const timeZone = "America/Argentina/Buenos_Aires";
const records = {
  "data/board.json": [
    {
      id: `board_${"a".repeat(64)}`,
      name: "Fixture board",
      time_zone: timeZone,
      created_at: timestamp,
      updated_at: timestamp,
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

async function* sourcesFor(overrides = records) {
  for (const [name, rows] of Object.entries(overrides)) {
    const content = Buffer.from(
      name.endsWith(".json")
        ? `${JSON.stringify(rows[0])}\n`
        : rows.map((row) => `${JSON.stringify(row)}\n`).join(""),
    );
    yield {
      name,
      contentType: name.endsWith(".json")
        ? "application/json"
        : "application/x-ndjson",
      recordCount: rows.length,
      expectedSize: content.byteLength,
      expectedSha256: createHash("sha256").update(content).digest("hex"),
      chunks: (async function* () {
        for (let offset = 0; offset < content.byteLength; offset += 31) {
          yield content.subarray(offset, offset + 31);
        }
      })(),
    };
  }
}

async function openFixture(overrides = records) {
  const folder = await mkdtemp(join(tmpdir(), "openkanban-v2-prepare-"));
  const path = join(folder, "backup.zip");
  const chunks = [];
  for await (const chunk of createPortableZipStream(sourcesFor(overrides), {
    exportedAt: timestamp,
    schemaVersion: 68,
    timeZone,
    normalizationVersion: 1,
  })) {
    chunks.push(Buffer.from(chunk));
  }
  await writeFile(path, Buffer.concat(chunks));
  return { folder, zip: await openPortableBoardImportZip(path) };
}

function fakeAdapter(overrides = {}) {
  const calls = [];
  const adapter = {
    async start(input) {
      calls.push(["start", input]);
      return { status: "staging" };
    },
    async stage(input) {
      calls.push(["stage", input]);
    },
    async reserve(input) {
      calls.push(["reserve", input]);
      return { targets: [] };
    },
    async upload(input) {
      calls.push(["upload", input]);
    },
    async finalize(input) {
      calls.push(["finalize", input]);
      return { status: "prepared", operation_id: "op" };
    },
    async cancel(input) {
      calls.push(["cancel", input]);
    },
    ...overrides,
  };
  return { adapter, calls };
}

test("imported activity without a verified actor remains valid for a later export", () => {
  const event = {
    id: `activity_${"8".repeat(64)}`,
    task_id: `task_${"c".repeat(64)}`,
    actor_type: "imported",
    category: "completion",
    actor_name: null,
    occurred_at: timestamp,
    before_value: false,
    after_value: true,
  };
  assert.deepEqual(validatePortableBoardImportRecord("activity", event), event);
});

test("v2 preparation stages the board and populated entities before reserving objects", async () => {
  const populated = {
    ...records,
    "data/columns.ndjson": [
      {
        id: `column_${"b".repeat(64)}`,
        title: "Ideas",
        position: 0,
        created_at: timestamp,
      },
    ],
    "data/tasks.ndjson": [
      {
        id: `task_${"c".repeat(64)}`,
        column_id: `column_${"b".repeat(64)}`,
        title: "Review the backup",
        description: null,
        priority: "medium",
        position: 0,
        due_on: null,
        is_completed: false,
        completed_at: null,
        steps: [],
        created_at: timestamp,
        updated_at: timestamp,
        assignee_ref: null,
      },
    ],
  };
  const fixture = await openFixture(populated);
  const { adapter, calls } = fakeAdapter();
  try {
    await preparePortableBoardImport(
      fixture.zip,
      "f".repeat(64),
      "operation-id",
      adapter,
    );
    const stages = calls
      .filter(([kind]) => kind === "stage")
      .map(([, input]) => input);
    assert.deepEqual(
      stages.map((stage) => stage.entity),
      ["board", "columns", "tasks"],
    );
    assert.deepEqual(stages[0].records[0], records["data/board.json"][0]);
    assert.equal(stages[1].records[0].title, "Ideas");
    assert.equal(stages[2].records[0].title, "Review the backup");
    assert.ok(
      calls.findIndex(([kind]) => kind === "reserve") >
        calls.findIndex(([kind]) => kind === "stage"),
    );
    assert.equal(calls.filter(([kind]) => kind === "finalize").length, 1);
    assert.equal(calls.filter(([kind]) => kind === "cancel").length, 0);
  } finally {
    await fixture.zip.close();
    await rm(fixture.folder, { recursive: true, force: true });
  }
});

test("v2 preparation cancels the invisible operation when a staged entity is invalid", async () => {
  const invalid = {
    ...records,
    "data/columns.ndjson": [
      {
        id: `column_${"b".repeat(64)}`,
        title: " ",
        position: 0,
        created_at: timestamp,
      },
    ],
  };
  const fixture = await openFixture(invalid);
  const { adapter, calls } = fakeAdapter();
  try {
    await assert.rejects(
      preparePortableBoardImport(
        fixture.zip,
        "f".repeat(64),
        "operation-id",
        adapter,
      ),
    );
    assert.equal(calls.filter(([kind]) => kind === "cancel").length, 1);
    assert.equal(calls.filter(([kind]) => kind === "reserve").length, 0);
    assert.equal(calls.filter(([kind]) => kind === "finalize").length, 0);
  } finally {
    await fixture.zip.close();
    await rm(fixture.folder, { recursive: true, force: true });
  }
});
