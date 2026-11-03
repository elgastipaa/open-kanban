import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { preparePortableBoardImport } from "../../src/lib/portable-board-import.ts";
import { createPortableBoardImportAdapter } from "../../src/lib/portable-board-import-adapter.ts";
import { openPortableBoardImportZip } from "../../src/lib/portable-board-import-zip.ts";
import { createPortableZipStream } from "../../src/lib/portable-export-zip.ts";

const timestamp = "2026-11-02T12:00:00.000Z";
const timeZone = "America/Argentina/Buenos_Aires";
const sourceRef = `attachment_${"d".repeat(64)}`;
const attachmentId = "11111111-1111-4111-8111-111111111111";
const objectKey = `attachments/${attachmentId}`;
const objectBytes = Buffer.from("fixture attachment");
const objectSha256 = createHash("sha256").update(objectBytes).digest("hex");

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
  "data/comments.ndjson": [
    {
      id: `comment_${"f".repeat(64)}`,
      task_id: `task_${"c".repeat(64)}`,
      author_name: "Ana histórica",
      content: "Texto importado sin menciones activas.",
      created_at: timestamp,
      edited_at: null,
      version: 1,
    },
  ],
  "data/labels.ndjson": [
    {
      id: `label_${"1".repeat(64)}`,
      name: "Operación",
      color: "blue",
      created_at: timestamp,
      updated_at: timestamp,
    },
  ],
  "data/task-labels.ndjson": [
    {
      task_id: `task_${"c".repeat(64)}`,
      label_id: `label_${"1".repeat(64)}`,
    },
  ],
  "data/birthdays.ndjson": [
    {
      id: `birthday_${"2".repeat(64)}`,
      name: "Cumple sintético",
      birth_month: 2,
      birth_day: 28,
      advance_days: 3,
      created_at: timestamp,
      updated_at: timestamp,
    },
  ],
  "data/birthday-labels.ndjson": [
    {
      birthday_id: `birthday_${"2".repeat(64)}`,
      label_id: `label_${"1".repeat(64)}`,
    },
  ],
  "data/repetitions.ndjson": [
    {
      id: `repetition_${"3".repeat(64)}`,
      origin_task_id: `task_${"c".repeat(64)}`,
      first_task_id: `task_${"c".repeat(64)}`,
      appearance_column_id: `column_${"b".repeat(64)}`,
      rule: "daily",
      start_on: "2026-11-01",
      end_on: null,
      occurrence_limit: null,
      consumed_count: 2,
      latest_occurrence_on: "2026-11-02",
      current_occurrence_id: null,
      next_due_on: null,
      state: "stopped",
      calendar_pattern: { frequency: "daily", interval: 1 },
      advance_days: 1,
      template_snapshot: {
        title: "Serie conservada",
        description: null,
        priority: "medium",
        assignee_ref: null,
        steps: [],
        redacted: false,
      },
      created_at: timestamp,
      updated_at: timestamp,
      stopped_at: timestamp,
    },
  ],
  "data/repetition-labels.ndjson": [
    {
      series_id: `repetition_${"3".repeat(64)}`,
      label_id: `label_${"1".repeat(64)}`,
    },
  ],
  "data/repetition-occurrences.ndjson": [
    {
      id: `occurrence_${"4".repeat(64)}`,
      series_id: `repetition_${"3".repeat(64)}`,
      occurrence_on: "2026-11-02",
      task_id: `task_${"c".repeat(64)}`,
      state: "excluded",
      due_on_override: "2026-11-03",
      transferred_to_series_id: null,
      created_at: timestamp,
    },
  ],
  "data/activity.ndjson": [
    {
      id: `activity_${"5".repeat(64)}`,
      task_id: `task_${"c".repeat(64)}`,
      actor_type: "user",
      category: "due_date",
      actor_name: "Ana histórica",
      occurred_at: timestamp,
      before_value: "2026-11-01",
      after_value: "2026-11-02",
    },
  ],
  "data/attachments.ndjson": [
    {
      id: sourceRef,
      task_id: `task_${"c".repeat(64)}`,
      file_name: "notes.txt",
      size_bytes: objectBytes.byteLength,
      sha256: objectSha256,
      created_at: timestamp,
    },
  ],
};

async function* zipSources() {
  for (const [name, rows] of Object.entries(records)) {
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
        yield content;
      })(),
    };
  }
  yield {
    name: `objects/${sourceRef}.txt`,
    contentType: "text/plain; charset=utf-8",
    expectedSize: objectBytes.byteLength,
    expectedSha256: objectSha256,
    chunks: (async function* () {
      yield objectBytes;
    })(),
  };
}

async function openFixture() {
  const folder = await mkdtemp(join(tmpdir(), "openkanban-v2-storage-"));
  const path = join(folder, "backup.zip");
  const chunks = [];
  for await (const chunk of createPortableZipStream(zipSources(), {
    exportedAt: timestamp,
    schemaVersion: 68,
    timeZone,
    normalizationVersion: 1,
  }))
    chunks.push(Buffer.from(chunk));
  await writeFile(path, Buffer.concat(chunks));
  return { folder, zip: await openPortableBoardImportZip(path) };
}

function setupAdapter({
  failUpload = false,
  failRemove = false,
  failFinalize = false,
  leaveObjectAfterRemove = false,
  listUnavailable = false,
} = {}) {
  const events = [];
  const stored = new Map();
  const target = {
    source_ref: sourceRef,
    attachment_id: attachmentId,
    file_name: "notes.txt",
    size_bytes: objectBytes.byteLength,
    sha256: objectSha256,
    object_key: objectKey,
    uploaded: false,
  };
  const storage = {
    async rpc(name, args) {
      events.push(["storage-rpc", name, args]);
      if (name === "mark_board_import_v2_object_uploaded_p") {
        return { data: { status: "uploaded" }, error: null };
      }
      if (name === "complete_board_import_v2_object_cleanup_p") {
        return { data: { status: "cleaned" }, error: null };
      }
      throw new Error(`Unexpected storage RPC ${name}`);
    },
    storage: {
      from(bucket) {
        assert.equal(bucket, "task-attachments");
        return {
          async upload(path, bytes, options) {
            events.push(["upload", path, Buffer.from(bytes), options]);
            if (failUpload)
              return { error: new Error("synthetic Storage failure") };
            stored.set(path, Buffer.from(bytes));
            return { error: null };
          },
          async download(path) {
            events.push(["download", path]);
            const bytes = stored.get(path);
            return { data: bytes ? new Blob([bytes]) : null, error: null };
          },
          async remove(paths) {
            events.push(["remove", ...paths]);
            if (failRemove)
              return { error: new Error("synthetic delete uncertainty") };
            if (!leaveObjectAfterRemove) {
              for (const path of paths) stored.delete(path);
            }
            return { error: null };
          },
          async list(prefix, options) {
            events.push(["list", prefix, options]);
            if (listUnavailable) {
              return {
                data: null,
                error: new Error("synthetic inventory failure"),
              };
            }
            return {
              data: stored.has(objectKey) ? [{ name: attachmentId }] : [],
              error: null,
            };
          },
        };
      },
    },
  };
  const client = {
    async rpc(name, args) {
      events.push(["client-rpc", name, args]);
      if (name === "prepare_board_import_v2_p")
        return { data: { status: "staging" }, error: null };
      if (name === "stage_board_import_v2_batch_p")
        return { data: { status: "staging" }, error: null };
      if (name === "reserve_board_import_v2_p") {
        return { data: { status: "reserved", targets: [target] }, error: null };
      }
      if (name === "finalize_board_import_v2_p") {
        if (failFinalize) {
          return { data: null, error: new Error("synthetic finalize failure") };
        }
        return {
          data: { status: "prepared", operation_id: "operation" },
          error: null,
        };
      }
      if (name === "cancel_board_import_v2_p") {
        return {
          data: {
            status: "cancelled",
            objects: [
              {
                attachment_id: attachmentId,
                object_key: objectKey,
                uploaded: false,
              },
            ],
          },
          error: null,
        };
      }
      throw new Error(`Unexpected client RPC ${name}`);
    },
  };
  return {
    events,
    stored,
    target,
    adapter: createPortableBoardImportAdapter({
      client,
      storage,
      actorId: "22222222-2222-4222-8222-222222222222",
      slug: "fixture-board",
    }),
  };
}

test("populated v2 ZIP exports, parses, stages every entity relation, then reserves and uploads objects", async () => {
  const fixture = await openFixture();
  const { adapter, events, stored } = setupAdapter();
  try {
    await preparePortableBoardImport(
      fixture.zip,
      "f".repeat(64),
      "operation",
      adapter,
    );
    const names = events.map((event) =>
      event[0].endsWith("-rpc") ? event[1] : event[0],
    );
    assert.ok(
      names.indexOf("reserve_board_import_v2_p") < names.indexOf("upload"),
    );
    assert.ok(names.indexOf("upload") < names.indexOf("download"));
    assert.ok(
      names.indexOf("download") <
        names.indexOf("mark_board_import_v2_object_uploaded_p"),
    );
    assert.ok(
      names.indexOf("mark_board_import_v2_object_uploaded_p") <
        names.indexOf("finalize_board_import_v2_p"),
    );
    const stagedBatches = events
      .filter(
        (event) =>
          event[0] === "client-rpc" &&
          event[1] === "stage_board_import_v2_batch_p",
      )
      .map((event) => event[2]);
    assert.deepEqual(
      stagedBatches.map((batch) => batch.p_entity),
      [
        "board",
        "columns",
        "tasks",
        "comments",
        "labels",
        "task_labels",
        "birthdays",
        "birthday_labels",
        "repetitions",
        "repetition_labels",
        "repetition_occurrences",
        "activity",
        "attachments",
      ],
    );
    assert.ok(
      stagedBatches.every(
        (batch) => Array.isArray(batch.p_records) && batch.p_records.length > 0,
      ),
    );
    const recordsByEntity = new Map(
      stagedBatches.map((batch) => [batch.p_entity, batch.p_records]),
    );
    const task = recordsByEntity.get("tasks")[0];
    const column = recordsByEntity.get("columns")[0];
    const label = recordsByEntity.get("labels")[0];
    const repetition = recordsByEntity.get("repetitions")[0];
    const occurrence = recordsByEntity.get("repetition_occurrences")[0];
    assert.equal(task.column_id, column.id);
    assert.equal(recordsByEntity.get("comments")[0].task_id, task.id);
    assert.deepEqual(recordsByEntity.get("task_labels")[0], {
      task_id: task.id,
      label_id: label.id,
    });
    assert.equal(recordsByEntity.get("birthday_labels")[0].label_id, label.id);
    assert.equal(
      recordsByEntity.get("repetition_labels")[0].series_id,
      repetition.id,
    );
    assert.equal(occurrence.series_id, repetition.id);
    assert.equal(occurrence.state, "excluded");
    assert.equal(
      recordsByEntity.get("activity")[0].actor_name,
      "Ana histórica",
    );
    assert.equal(recordsByEntity.get("attachments")[0].id, sourceRef);
    assert.deepEqual(stored.get(objectKey), objectBytes);
    const upload = events.find(([kind]) => kind === "upload");
    assert.equal(upload[1], objectKey);
    assert.equal(upload[3].upsert, true);
  } finally {
    await fixture.zip.close();
    await rm(fixture.folder, { recursive: true, force: true });
  }
});

test("retrying the same reserved object uses an idempotent Storage upsert", async () => {
  const fixture = await openFixture();
  const { adapter, events, stored, target } = setupAdapter();
  try {
    await adapter.upload({
      operationId: "operation",
      target,
      bytes: objectBytes,
    });
    await adapter.upload({
      operationId: "operation",
      target,
      bytes: objectBytes,
    });
    assert.equal(events.filter(([kind]) => kind === "upload").length, 2);
    assert.equal(
      events.filter(
        ([, name]) => name === "mark_board_import_v2_object_uploaded_p",
      ).length,
      2,
    );
    assert.deepEqual(stored.get(objectKey), objectBytes);
    assert.ok(
      events
        .filter(([kind]) => kind === "upload")
        .every(([, , , options]) => options.upsert === true),
    );
  } finally {
    await fixture.zip.close();
    await rm(fixture.folder, { recursive: true, force: true });
  }
});

test("Storage failure cancels preparation and retains quota metadata without delete acknowledgement", async () => {
  const fixture = await openFixture();
  const { adapter, events } = setupAdapter({
    failUpload: true,
    failRemove: true,
  });
  try {
    await assert.rejects(
      preparePortableBoardImport(
        fixture.zip,
        "f".repeat(64),
        "operation",
        adapter,
      ),
      /No se pudo almacenar/u,
    );
    const names = events.map((event) =>
      event[0].endsWith("-rpc") ? event[1] : event[0],
    );
    assert.ok(names.includes("cancel_board_import_v2_p"));
    assert.ok(names.includes("remove"));
    assert.ok(!names.includes("complete_board_import_v2_object_cleanup_p"));
    assert.ok(!names.includes("finalize_board_import_v2_p"));
  } finally {
    await fixture.zip.close();
    await rm(fixture.folder, { recursive: true, force: true });
  }
});

test("a successful remove response does not release metadata while inventory still lists the object", async () => {
  const fixture = await openFixture();
  const { adapter, events, stored } = setupAdapter({
    failFinalize: true,
    leaveObjectAfterRemove: true,
  });
  try {
    await assert.rejects(
      preparePortableBoardImport(
        fixture.zip,
        "f".repeat(64),
        "operation",
        adapter,
      ),
      /No se pudo finalizar/u,
    );
    assert.equal(stored.has(objectKey), true);
    assert.ok(events.some(([kind]) => kind === "remove"));
    assert.ok(events.some(([kind]) => kind === "list"));
    assert.ok(
      !events.some(
        ([kind, name]) =>
          kind === "storage-rpc" &&
          name === "complete_board_import_v2_object_cleanup_p",
      ),
    );
  } finally {
    await fixture.zip.close();
    await rm(fixture.folder, { recursive: true, force: true });
  }
});

test("an incomplete Storage inventory cannot acknowledge cleanup", async () => {
  const fixture = await openFixture();
  const { adapter, events } = setupAdapter({
    failFinalize: true,
    listUnavailable: true,
  });
  try {
    await assert.rejects(
      preparePortableBoardImport(
        fixture.zip,
        "f".repeat(64),
        "operation",
        adapter,
      ),
      /No se pudo finalizar/u,
    );
    assert.ok(events.some(([kind]) => kind === "list"));
    assert.ok(
      !events.some(
        ([kind, name]) =>
          kind === "storage-rpc" &&
          name === "complete_board_import_v2_object_cleanup_p",
      ),
    );
  } finally {
    await fixture.zip.close();
    await rm(fixture.folder, { recursive: true, force: true });
  }
});
