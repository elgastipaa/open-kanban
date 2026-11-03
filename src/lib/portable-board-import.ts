import { createHash } from "node:crypto";
import { z } from "zod/v4";
import {
  MAX_PORTABLE_BOARD_ATTACHMENT_BYTES,
  MAX_PORTABLE_BOARD_RECORD_BYTES,
  MAX_PORTABLE_BOARD_RECORDS,
} from "./portable-board-import-limits.ts";
import type {
  PortableBoardImportManifest,
  PortableBoardImportZip,
} from "./portable-board-import-zip";

const MEMBER_REF = /^member_[0-9a-f]{64}$/u;
const STEP_ID = /^step_[0-9a-f]{64}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const DATE = /^\d{4}-\d{2}-\d{2}$/u;
const MAX_RECORD_BYTES = MAX_PORTABLE_BOARD_RECORD_BYTES;
const MAX_BATCH_BYTES = 256 * 1024;
const MAX_BATCH_RECORDS = 100;

function hasControlCharacters(value: string): boolean {
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0;
    if (codePoint <= 0x1f || (codePoint >= 0x7f && codePoint <= 0x9f)) {
      return true;
    }
  }
  return false;
}

const calendarDate = z
  .string()
  .regex(DATE)
  .refine((value) => {
    const [year, month, day] = value.split("-").map(Number);
    if (year < 1 || month < 1 || month > 12) return false;
    const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    const daysInMonth = [
      31,
      leap ? 29 : 28,
      31,
      30,
      31,
      30,
      31,
      31,
      30,
      31,
      30,
      31,
    ];
    return day >= 1 && day <= daysInMonth[month - 1];
  });
const nullableDate = calendarDate.nullable();
const timestamp = z
  .string()
  .min(1)
  .max(100)
  .refine((value) => Number.isFinite(Date.parse(value)));
const stepSchema = z
  .object({
    id: z.string().regex(STEP_ID),
    text: z.string().min(1).max(1000),
    is_completed: z.boolean(),
    position: z.number().int().safe().nonnegative(),
  })
  .strict();
const stepsSchema = z.array(stepSchema).max(1000);
const priority = z.enum(["low", "medium", "high", "urgent"]);
const memberRef = z.string().regex(MEMBER_REF).nullable();

const recordSchemas = {
  board: z
    .object({
      id: z.string().regex(/^board_[0-9a-f]{64}$/u),
      name: z.string().trim().min(1).max(100),
      time_zone: z.string().min(1).max(100),
      created_at: timestamp,
      updated_at: timestamp,
    })
    .strict(),
  columns: z
    .object({
      id: z.string().regex(/^column_[0-9a-f]{64}$/u),
      title: z.string().trim().min(1).max(100),
      position: z.number().int().safe().nonnegative().max(2_147_483_647),
      created_at: timestamp,
    })
    .strict(),
  tasks: z
    .object({
      id: z.string().regex(/^task_[0-9a-f]{64}$/u),
      column_id: z.string().regex(/^column_[0-9a-f]{64}$/u),
      title: z.string().trim().min(1).max(200),
      description: z.string().max(2000).nullable(),
      priority,
      position: z.number().int().safe().nonnegative().max(2_147_483_647),
      due_on: nullableDate,
      is_completed: z.boolean(),
      completed_at: timestamp.nullable(),
      steps: stepsSchema,
      created_at: timestamp,
      updated_at: timestamp,
      assignee_ref: memberRef,
    })
    .strict(),
  comments: z
    .object({
      id: z.string().regex(/^comment_[0-9a-f]{64}$/u),
      task_id: z.string().regex(/^task_[0-9a-f]{64}$/u),
      author_name: z.string().trim().min(1).max(1000),
      content: z.string().trim().min(1),
      created_at: timestamp,
      edited_at: timestamp.nullable(),
      version: z.number().int().safe().positive(),
    })
    .strict(),
  labels: z
    .object({
      id: z.string().regex(/^label_[0-9a-f]{64}$/u),
      name: z.string().trim().min(1).max(40),
      color: z.enum([
        "red",
        "orange",
        "yellow",
        "green",
        "teal",
        "blue",
        "purple",
        "pink",
        "gray",
      ]),
      created_at: timestamp,
      updated_at: timestamp,
    })
    .strict(),
  task_labels: z
    .object({
      task_id: z.string().regex(/^task_[0-9a-f]{64}$/u),
      label_id: z.string().regex(/^label_[0-9a-f]{64}$/u),
    })
    .strict(),
  birthdays: z
    .object({
      id: z.string().regex(/^birthday_[0-9a-f]{64}$/u),
      name: z.string().trim().min(1).max(100),
      birth_month: z.number().int().min(1).max(12),
      birth_day: z.number().int().min(1).max(31),
      advance_days: z.number().int().min(0).max(366).nullable(),
      created_at: timestamp,
      updated_at: timestamp,
    })
    .strict(),
  birthday_labels: z
    .object({
      birthday_id: z.string().regex(/^birthday_[0-9a-f]{64}$/u),
      label_id: z.string().regex(/^label_[0-9a-f]{64}$/u),
    })
    .strict(),
  repetitions: z
    .object({
      id: z.string().regex(/^repetition_[0-9a-f]{64}$/u),
      origin_task_id: z.string().regex(/^task_[0-9a-f]{64}$/u),
      first_task_id: z.string().regex(/^task_[0-9a-f]{64}$/u),
      appearance_column_id: z.string().regex(/^column_[0-9a-f]{64}$/u),
      rule: z.enum(["daily", "weekly"]),
      start_on: calendarDate,
      end_on: nullableDate,
      occurrence_limit: z.number().int().safe().positive().nullable(),
      consumed_count: z.number().int().safe().positive(),
      latest_occurrence_on: calendarDate,
      current_occurrence_id: z
        .string()
        .regex(/^occurrence_[0-9a-f]{64}$/u)
        .nullable(),
      next_due_on: nullableDate,
      state: z.enum(["active", "stopped", "finished"]),
      calendar_pattern: z
        .object({
          frequency: z.enum(["daily", "weekly"]),
          interval: z.number().int().positive().max(2_147_483_647),
          weekdays: z
            .array(z.number().int().min(1).max(7))
            .min(1)
            .max(7)
            .refine((days) => new Set(days).size === days.length)
            .optional(),
        })
        .strict(),
      advance_days: z.number().int().min(0).max(366),
      template_snapshot: z
        .object({
          title: z.string().trim().min(1).max(200),
          description: z.string().max(2000).nullable(),
          priority,
          assignee_ref: memberRef,
          steps: stepsSchema,
          redacted: z.boolean().nullable(),
        })
        .strict(),
      created_at: timestamp,
      updated_at: timestamp,
      stopped_at: timestamp.nullable(),
    })
    .strict(),
  repetition_labels: z
    .object({
      series_id: z.string().regex(/^repetition_[0-9a-f]{64}$/u),
      label_id: z.string().regex(/^label_[0-9a-f]{64}$/u),
    })
    .strict(),
  repetition_occurrences: z
    .object({
      id: z.string().regex(/^occurrence_[0-9a-f]{64}$/u),
      series_id: z.string().regex(/^repetition_[0-9a-f]{64}$/u),
      occurrence_on: calendarDate,
      task_id: z.string().regex(/^task_[0-9a-f]{64}$/u),
      state: z.enum([
        "current",
        "replaced",
        "excluded",
        "purged",
        "transferred",
      ]),
      due_on_override: nullableDate,
      transferred_to_series_id: z
        .string()
        .regex(/^repetition_[0-9a-f]{64}$/u)
        .nullable(),
      created_at: timestamp,
    })
    .strict(),
  activity: z
    .object({
      id: z.string().regex(/^activity_[0-9a-f]{64}$/u),
      task_id: z.string().regex(/^task_[0-9a-f]{64}$/u),
      actor_type: z.enum(["user", "system", "imported"]),
      category: z.enum([
        "assignee",
        "due_date",
        "column",
        "completion",
        "recovery",
      ]),
      actor_name: z.string().trim().min(1).max(1000).nullable(),
      occurred_at: timestamp,
      before_value: z.union([z.string(), z.boolean(), z.null()]),
      after_value: z.union([z.string(), z.boolean(), z.null()]),
    })
    .strict(),
  attachments: z
    .object({
      id: z.string().regex(/^attachment_[0-9a-f]{64}$/u),
      task_id: z.string().regex(/^task_[0-9a-f]{64}$/u),
      file_name: z
        .string()
        .trim()
        .min(1)
        .max(120)
        .regex(/\.(?:txt|md)$/iu)
        .refine(
          (name) =>
            !hasControlCharacters(name) &&
            !name.includes("/") &&
            !name.includes("\\"),
        ),
      size_bytes: z
        .number()
        .int()
        .min(1)
        .max(MAX_PORTABLE_BOARD_ATTACHMENT_BYTES),
      sha256: z.string().regex(SHA256),
      created_at: timestamp,
    })
    .strict(),
} satisfies Record<string, z.ZodType>;

const entityByPath = Object.freeze({
  "data/board.json": "board",
  "data/columns.ndjson": "columns",
  "data/tasks.ndjson": "tasks",
  "data/comments.ndjson": "comments",
  "data/labels.ndjson": "labels",
  "data/task-labels.ndjson": "task_labels",
  "data/birthdays.ndjson": "birthdays",
  "data/birthday-labels.ndjson": "birthday_labels",
  "data/repetitions.ndjson": "repetitions",
  "data/repetition-labels.ndjson": "repetition_labels",
  "data/repetition-occurrences.ndjson": "repetition_occurrences",
  "data/activity.ndjson": "activity",
  "data/attachments.ndjson": "attachments",
} as const);

export type PortableBoardImportEntity = keyof typeof recordSchemas;
export type ImportOperationStatus = "staging" | "prepared" | "confirmed";

export interface PortableBoardImportObjectTarget {
  source_ref: string;
  attachment_id: string;
  file_name: string;
  size_bytes: number;
  sha256: string;
  object_key: string;
  uploaded: boolean;
}

export interface PortableBoardImportPreview {
  status: "prepared" | "label_conflict";
  operation_id: string;
  content_revision: number;
  source_sha256: string;
  expires_at: string;
  time_zone: string;
  current: Record<string, number>;
  imported: Record<string, number>;
  capacity: {
    limit_bytes: number;
    used_bytes: number;
    available_bytes: number;
    can_replace: boolean;
  };
  member_refs: string[];
  member_mappings: Array<{ source_ref: string; target_user_id: string | null }>;
  members: Array<{ user_id: string; name: string }>;
  label_renames: Array<{
    source_ref: string;
    name: string;
    imported_name: string;
  }>;
  label_conflicts?: PortableBoardImportLabelConflict[];
}

export interface PortableBoardImportLabelConflict {
  source_ref: string;
  name: string;
  conflict_name: string;
}

export interface PortableBoardImportAdapter {
  start(input: {
    operationId: string;
    sourceSha256: string;
    manifest: PortableBoardImportManifest;
  }): Promise<{
    status: ImportOperationStatus | "unavailable" | "invalid";
    preview?: PortableBoardImportPreview;
  }>;
  stage(input: {
    operationId: string;
    entity: PortableBoardImportEntity;
    batchIndex: number;
    records: Record<string, unknown>[];
  }): Promise<void>;
  reserve(input: { operationId: string }): Promise<{
    targets: PortableBoardImportObjectTarget[];
  }>;
  upload(input: {
    operationId: string;
    target: PortableBoardImportObjectTarget;
    bytes: Uint8Array;
  }): Promise<void>;
  finalize(input: { operationId: string }): Promise<PortableBoardImportPreview>;
  cancel(input: { operationId: string }): Promise<void>;
}

export function validatePortableBoardImportRecord(
  entity: PortableBoardImportEntity,
  value: unknown,
): Record<string, unknown> {
  const parsed = recordSchemas[entity].parse(value) as Record<string, unknown>;
  if (entity === "repetitions") {
    const repetition = parsed as z.infer<typeof recordSchemas.repetitions>;
    if (
      (repetition.state === "active" &&
        (repetition.next_due_on === null || repetition.stopped_at !== null)) ||
      (repetition.state === "stopped" &&
        (repetition.next_due_on !== null || repetition.stopped_at === null)) ||
      (repetition.state === "finished" &&
        (repetition.next_due_on !== null || repetition.stopped_at !== null)) ||
      repetition.rule !== repetition.calendar_pattern.frequency ||
      (repetition.rule === "daily" &&
        (repetition.calendar_pattern.interval !== 1 ||
          repetition.calendar_pattern.weekdays !== undefined)) ||
      (repetition.rule === "weekly" &&
        repetition.calendar_pattern.weekdays === undefined)
    ) {
      throw new Error("La regla de calendario del respaldo no es válida.");
    }
  }
  if (entity === "tasks") {
    const task = parsed as z.infer<typeof recordSchemas.tasks>;
    if (task.is_completed !== (task.completed_at !== null)) {
      throw new Error(
        "El estado de finalización de una tarea del respaldo no es válido.",
      );
    }
  }
  if (entity === "repetition_occurrences") {
    const occurrence = parsed as z.infer<
      typeof recordSchemas.repetition_occurrences
    >;
    if (
      (occurrence.state === "transferred") !==
      (occurrence.transferred_to_series_id !== null)
    ) {
      throw new Error(
        "La relación de una ocurrencia transferida no es válida.",
      );
    }
  }
  if (entity === "activity") {
    const activity = parsed as z.infer<typeof recordSchemas.activity>;
    if (
      (activity.actor_type === "system" && activity.actor_name !== null) ||
      (activity.actor_type === "user" && activity.actor_name === null) ||
      (activity.category === "recovery" &&
        (activity.before_value !== null || activity.after_value !== null)) ||
      (activity.category !== "recovery" &&
        (activity.before_value === null || activity.after_value === null)) ||
      (activity.category === "completion" &&
        (typeof activity.before_value !== "boolean" ||
          typeof activity.after_value !== "boolean")) ||
      (activity.category !== "completion" &&
        activity.category !== "recovery" &&
        (typeof activity.before_value !== "string" ||
          typeof activity.after_value !== "string"))
    ) {
      throw new Error(
        "La atribución de una actividad del respaldo no es válida.",
      );
    }
  }
  return parsed as Record<string, unknown>;
}

async function* ndjsonRecords(
  chunks: AsyncIterable<Uint8Array>,
  path: string,
): AsyncGenerator<{ record: unknown; bytes: number }> {
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let pending = "";
  let pendingBytes = 0;
  for await (const chunk of chunks) {
    pending += decoder.decode(chunk, { stream: true });
    let newline = pending.indexOf("\n");
    while (newline >= 0) {
      const line = pending.slice(0, newline);
      const lineBytes = new TextEncoder().encode(`${line}\n`).byteLength;
      pending = pending.slice(newline + 1);
      if (line.length === 0 || line.endsWith("\r")) {
        throw new Error(
          "El contenido de una entidad del respaldo no es NDJSON canónico.",
        );
      }
      let record: unknown;
      try {
        record = JSON.parse(line);
      } catch {
        throw new Error(`El archivo ${path} contiene una línea JSON inválida.`);
      }
      yield { record, bytes: lineBytes };
      pendingBytes = new TextEncoder().encode(pending).byteLength;
      if (pendingBytes > MAX_RECORD_BYTES) {
        throw new Error(
          "Un registro del respaldo supera el presupuesto de lectura.",
        );
      }
      newline = pending.indexOf("\n");
    }
    pendingBytes = new TextEncoder().encode(pending).byteLength;
    if (pendingBytes > MAX_RECORD_BYTES) {
      throw new Error(
        "Un registro del respaldo supera el presupuesto de lectura.",
      );
    }
  }
  pending += decoder.decode();
  if (pending.length !== 0) {
    throw new Error("Una entidad del respaldo terminó sin separador de línea.");
  }
}

async function parseBoardFile(
  zip: PortableBoardImportZip,
  path: string,
): Promise<Record<string, unknown>> {
  const chunks: Uint8Array[] = [];
  let size = 0;
  for await (const chunk of zip.readVerified(path)) {
    size += chunk.byteLength;
    if (size > MAX_RECORD_BYTES)
      throw new Error("El tablero del respaldo supera el límite de lectura.");
    chunks.push(chunk);
  }
  const text = new TextDecoder("utf-8", { fatal: true }).decode(
    Buffer.concat(chunks),
  );
  if (!text.endsWith("\n"))
    throw new Error("El registro del tablero no es NDJSON canónico.");
  const lines = text.slice(0, -1).split("\n");
  if (lines.length !== 1)
    throw new Error("El paquete debe contener un solo registro de tablero.");
  let record: unknown;
  try {
    record = JSON.parse(lines[0]);
  } catch {
    throw new Error("El tablero del respaldo no contiene JSON válido.");
  }
  return validatePortableBoardImportRecord("board", record);
}

async function* objectBytes(
  zip: PortableBoardImportZip,
  path: string,
  expectedSize: number,
): AsyncGenerator<Uint8Array> {
  let size = 0;
  for await (const chunk of zip.readVerified(path)) {
    size += chunk.byteLength;
    if (size > expectedSize || size > MAX_PORTABLE_BOARD_ATTACHMENT_BYTES)
      throw new Error("El adjunto supera el tamaño permitido.");
    yield chunk;
  }
  if (size !== expectedSize)
    throw new Error("El tamaño del adjunto no coincide con el manifiesto.");
}

function attachmentObjectPath(target: PortableBoardImportObjectTarget): string {
  const extension = /\.md$/iu.test(target.file_name) ? "md" : "txt";
  return `objects/${target.source_ref}.${extension}`;
}

export async function preparePortableBoardImport(
  zip: PortableBoardImportZip,
  sourceSha256: string,
  operationId: string,
  adapter: PortableBoardImportAdapter,
): Promise<PortableBoardImportPreview> {
  const started = await adapter.start({
    operationId,
    sourceSha256,
    manifest: zip.manifest,
  });
  if (started.status === "prepared" && started.preview) return started.preview;
  if (started.status === "confirmed" && started.preview) return started.preview;
  if (started.status !== "staging") {
    throw new Error("No se pudo iniciar la preparación del respaldo.");
  }

  try {
    const boardRecord = await parseBoardFile(zip, "data/board.json");
    if (boardRecord.time_zone !== zip.manifest.calendar.time_zone) {
      throw new Error(
        "La zona horaria del manifiesto no coincide con el tablero.",
      );
    }
    await adapter.stage({
      operationId,
      entity: "board",
      batchIndex: 0,
      records: [boardRecord],
    });
    let totalRecords = 1;
    for (const [path, entity] of Object.entries(entityByPath)) {
      const metadata = zip.manifest.files.find((file) => file.path === path);
      if (!metadata)
        throw new Error("El manifiesto no declara una entidad requerida.");
      if (entity === "board") continue;
      let batch: Record<string, unknown>[] = [];
      let batchBytes = 0;
      let batchIndex = 0;
      let count = 0;
      for await (const item of ndjsonRecords(zip.readVerified(path), path)) {
        if (item.bytes > MAX_RECORD_BYTES) {
          throw new Error(
            "Un registro del respaldo supera el presupuesto de lectura.",
          );
        }
        const record = validatePortableBoardImportRecord(entity, item.record);
        if (
          batch.length > 0 &&
          (batch.length >= MAX_BATCH_RECORDS ||
            batchBytes + item.bytes > MAX_BATCH_BYTES)
        ) {
          await adapter.stage({
            operationId,
            entity,
            batchIndex,
            records: batch,
          });
          batchIndex += 1;
          batch = [];
          batchBytes = 0;
        }
        batch.push(record);
        batchBytes += item.bytes;
        count += 1;
        totalRecords += 1;
        if (totalRecords > MAX_PORTABLE_BOARD_RECORDS) {
          throw new Error(
            "El respaldo supera el límite de registros permitido.",
          );
        }
      }
      if (batch.length > 0) {
        await adapter.stage({
          operationId,
          entity,
          batchIndex,
          records: batch,
        });
      }
      if (count !== metadata.records) {
        throw new Error(
          "La cantidad de registros no coincide con el manifiesto.",
        );
      }
    }

    const reservation = await adapter.reserve({ operationId });
    const declaredObjectPaths = new Set(
      zip.manifest.files
        .filter((file) => file.path.startsWith("objects/"))
        .map((file) => file.path),
    );
    if (reservation.targets.length !== declaredObjectPaths.size) {
      throw new Error("La cantidad de adjuntos no coincide con el manifiesto.");
    }
    for (const target of reservation.targets) {
      const path = attachmentObjectPath(target);
      if (!declaredObjectPaths.delete(path)) {
        throw new Error(
          "El paquete no contiene el objeto declarado para un adjunto.",
        );
      }
      if (target.uploaded) continue;
      const chunks: Uint8Array[] = [];
      let size = 0;
      for await (const chunk of objectBytes(zip, path, target.size_bytes)) {
        chunks.push(chunk);
        size += chunk.byteLength;
      }
      const bytes = Buffer.concat(chunks);
      if (size !== target.size_bytes || createSha256(bytes) !== target.sha256) {
        throw new Error("El hash de un adjunto no coincide con su registro.");
      }
      await adapter.upload({ operationId, target, bytes });
    }
    if (declaredObjectPaths.size > 0)
      throw new Error("El manifiesto contiene objetos sin adjunto.");
    return await adapter.finalize({ operationId });
  } catch (error) {
    try {
      await adapter.cancel({ operationId });
    } catch {
      // The operation remains invisible and its bounded reservations expire.
    }
    throw error;
  }
}

export function createSha256(value: Uint8Array): string {
  return createHash("sha256").update(value).digest("hex");
}
