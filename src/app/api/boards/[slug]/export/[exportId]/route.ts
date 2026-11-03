import type { SupabaseClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import {
  createPortableZipStream,
  type PortableExportMetadata,
  type PortableZipSource,
} from "@/lib/portable-export-zip";
import {
  createTaskAttachmentServiceClient,
  TASK_ATTACHMENT_BUCKET,
} from "@/lib/supabase/task-attachment-storage";
import { getTaskAttachmentSession } from "@/lib/task-attachment-session";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = {
  params: Promise<{ slug: string; exportId: string }>;
};

type SnapshotItem = {
  ordinal: number;
  payload: Record<string, unknown>;
  object_key: string | null;
  expected_size: number | null;
  expected_sha256: string | null;
};

type SnapshotPage = {
  status: "page";
  created_at: string;
  schema_version: number;
  normalization_version: number;
  time_zone: string;
  entity: string;
  record_count: number;
  items: SnapshotItem[];
  has_more: boolean;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const PAGE_SIZE = 100;

function hasControlCharacters(value: string): boolean {
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0;
    if (codePoint <= 0x1f || (codePoint >= 0x7f && codePoint <= 0x9f)) {
      return true;
    }
  }
  return false;
}

function isSafeAttachmentFileName(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const length = Array.from(value).length;
  return (
    length >= 1 &&
    length <= 120 &&
    !hasControlCharacters(value) &&
    !value.includes("/") &&
    !value.includes("\\") &&
    /\.(?:txt|md)$/iu.test(value)
  );
}

const ENTITIES = [
  { entity: "board", path: "data/board.json", contentType: "application/json" },
  {
    entity: "columns",
    path: "data/columns.ndjson",
    contentType: "application/x-ndjson",
  },
  {
    entity: "tasks",
    path: "data/tasks.ndjson",
    contentType: "application/x-ndjson",
  },
  {
    entity: "comments",
    path: "data/comments.ndjson",
    contentType: "application/x-ndjson",
  },
  {
    entity: "labels",
    path: "data/labels.ndjson",
    contentType: "application/x-ndjson",
  },
  {
    entity: "task_labels",
    path: "data/task-labels.ndjson",
    contentType: "application/x-ndjson",
  },
  {
    entity: "birthdays",
    path: "data/birthdays.ndjson",
    contentType: "application/x-ndjson",
  },
  {
    entity: "birthday_labels",
    path: "data/birthday-labels.ndjson",
    contentType: "application/x-ndjson",
  },
  {
    entity: "repetitions",
    path: "data/repetitions.ndjson",
    contentType: "application/x-ndjson",
  },
  {
    entity: "repetition_labels",
    path: "data/repetition-labels.ndjson",
    contentType: "application/x-ndjson",
  },
  {
    entity: "repetition_occurrences",
    path: "data/repetition-occurrences.ndjson",
    contentType: "application/x-ndjson",
  },
  {
    entity: "activity",
    path: "data/activity.ndjson",
    contentType: "application/x-ndjson",
  },
  {
    entity: "attachments",
    path: "data/attachments.ndjson",
    contentType: "application/x-ndjson",
  },
] as const;

function unavailable(status = 404): NextResponse {
  return NextResponse.json(
    { status: "unavailable" },
    {
      status,
      headers: { "Cache-Control": "private, no-store, max-age=0" },
    },
  );
}

async function readPage(
  service: SupabaseClient,
  actorId: string,
  slug: string,
  exportId: string,
  entity: string,
  after: number,
): Promise<SnapshotPage> {
  const { data, error } = await service.rpc(
    "read_board_export_snapshot_page_p",
    {
      p_actor_id: actorId,
      p_board_slug: slug,
      p_export_id: exportId,
      p_entity: entity,
      p_after: after,
      p_limit: PAGE_SIZE,
    },
  );
  const page = data as SnapshotPage | null;
  if (
    error ||
    page?.status !== "page" ||
    page.entity !== entity ||
    !Number.isSafeInteger(page.record_count) ||
    page.record_count < 0 ||
    !Array.isArray(page.items) ||
    typeof page.has_more !== "boolean" ||
    !Number.isSafeInteger(page.schema_version) ||
    !Number.isSafeInteger(page.normalization_version) ||
    !page.time_zone ||
    !Number.isFinite(Date.parse(page.created_at))
  ) {
    throw new Error("No se pudo leer la instantánea del tablero.");
  }
  return page;
}

async function* recordChunks(
  service: SupabaseClient,
  actorId: string,
  slug: string,
  exportId: string,
  entity: string,
  firstPage: SnapshotPage,
): AsyncGenerator<Uint8Array> {
  const encoder = new TextEncoder();
  let after = 0;
  let seen = 0;
  let page = firstPage;
  for (;;) {
    for (const item of page.items) {
      if (!item || typeof item.payload !== "object" || item.payload === null) {
        throw new Error("La instantánea contiene un registro inválido.");
      }
      yield encoder.encode(`${JSON.stringify(item.payload)}\n`);
      after += 1;
      seen += 1;
    }
    if (!page.has_more) break;
    page = await readPage(service, actorId, slug, exportId, entity, after);
  }
  if (seen !== firstPage.record_count) {
    throw new Error("La instantánea quedó incompleta durante la descarga.");
  }
}

async function* attachmentSources(
  service: SupabaseClient,
  actorId: string,
  slug: string,
  exportId: string,
): AsyncGenerator<PortableZipSource> {
  let after = 0;
  let expectedCount: number | undefined;
  let seen = 0;
  for (;;) {
    const page = await readPage(
      service,
      actorId,
      slug,
      exportId,
      "attachments",
      after,
    );
    expectedCount ??= page.record_count;
    for (const item of page.items) {
      const attachmentRef = item.payload.id;
      const fileName = item.payload.file_name;
      const extension =
        typeof fileName === "string" && /\.md$/iu.test(fileName) ? "md" : "txt";
      const storageObjectId = item.object_key?.startsWith("attachments/")
        ? item.object_key.slice("attachments/".length)
        : "";
      if (
        typeof attachmentRef !== "string" ||
        !/^attachment_[0-9a-f]{64}$/iu.test(attachmentRef) ||
        !isSafeAttachmentFileName(fileName) ||
        !UUID_PATTERN.test(storageObjectId) ||
        item.object_key !== `attachments/${storageObjectId}` ||
        !Number.isSafeInteger(item.expected_size) ||
        typeof item.expected_sha256 !== "string" ||
        !/^[0-9a-f]{64}$/iu.test(item.expected_sha256)
      ) {
        throw new Error("Los metadatos de un adjunto no son válidos.");
      }
      const objectKey = item.object_key;
      const expectedSize = item.expected_size as number;
      const expectedSha256 = item.expected_sha256;
      yield {
        name: `objects/${attachmentRef}.${extension}`,
        contentType: "text/plain; charset=utf-8",
        expectedSize,
        expectedSha256,
        chunks: (async function* () {
          const { data, error } = await service.storage
            .from(TASK_ATTACHMENT_BUCKET)
            .download(objectKey);
          if (error || !data) {
            throw new Error("No se pudo leer un adjunto del tablero.");
          }
          const bytes = new Uint8Array(await data.arrayBuffer());
          yield bytes;
        })(),
      };
      after += 1;
      seen += 1;
    }
    if (!page.has_more) break;
  }
  if (expectedCount !== seen) {
    throw new Error("La lista de adjuntos quedó incompleta.");
  }
}

async function* exportSources(
  service: SupabaseClient,
  actorId: string,
  slug: string,
  exportId: string,
): AsyncGenerator<PortableZipSource> {
  let metadata: PortableExportMetadata | null = null;
  for (const entity of ENTITIES) {
    const page = await readPage(
      service,
      actorId,
      slug,
      exportId,
      entity.entity,
      0,
    );
    metadata ??= {
      exportedAt: page.created_at,
      schemaVersion: page.schema_version,
      timeZone: page.time_zone,
      normalizationVersion: page.normalization_version,
    };
    yield {
      name: entity.path,
      contentType: entity.contentType,
      recordCount: page.record_count,
      chunks: recordChunks(
        service,
        actorId,
        slug,
        exportId,
        entity.entity,
        page,
      ),
    };
  }
  yield* attachmentSources(service, actorId, slug, exportId);
  if (!metadata) throw new Error("La instantánea no tiene metadatos.");
}

function safeFileName(slug: string): string {
  const safeSlug = slug
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/gu, "")
    .replace(/[^a-zA-Z0-9_-]+/gu, "-")
    .replace(/^-+|-+$/gu, "")
    .slice(0, 64);
  return `openkanban-${safeSlug || "tablero"}-export.zip`;
}

export async function GET(
  _request: Request,
  { params }: RouteContext,
): Promise<Response> {
  const session = await getTaskAttachmentSession();
  if (!session) return unavailable();
  const { slug, exportId } = await params;
  if (!UUID_PATTERN.test(exportId)) return unavailable();

  let service: SupabaseClient;
  let firstPage: SnapshotPage;
  try {
    service = createTaskAttachmentServiceClient();
    firstPage = await readPage(
      service,
      session.actorId,
      slug,
      exportId,
      "board",
      0,
    );
    if (firstPage.record_count !== 1) return unavailable();
  } catch {
    return unavailable();
  }

  const sources = exportSources(service, session.actorId, slug, exportId);
  const zip = createPortableZipStream(sources, {
    exportedAt: firstPage.created_at,
    schemaVersion: firstPage.schema_version,
    timeZone: firstPage.time_zone,
    normalizationVersion: firstPage.normalization_version,
  });
  const stream = new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        const next = await zip.next();
        if (next.done) controller.close();
        else controller.enqueue(next.value);
      } catch {
        controller.error(new Error("La exportación no pudo completarse."));
        await service.rpc("delete_board_export_snapshot_p", {
          p_actor_id: session.actorId,
          p_export_id: exportId,
        });
      }
    },
    async cancel() {
      await zip.return(undefined);
      await service.rpc("delete_board_export_snapshot_p", {
        p_actor_id: session.actorId,
        p_export_id: exportId,
      });
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      "Content-Type": "application/zip",
      "Content-Disposition": `attachment; filename="${safeFileName(slug)}"`,
      "Cache-Control": "private, no-store, max-age=0",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
