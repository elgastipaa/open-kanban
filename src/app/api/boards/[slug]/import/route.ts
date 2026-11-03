import { NextResponse } from "next/server";
import { ZodError } from "zod/v4";
import {
  MAX_LEGACY_IMPORT_REQUEST_BYTES,
  readBoundedRequestBody,
  readLegacyBoardImportFile,
} from "@/lib/import";
import { preparePortableBoardImport } from "@/lib/portable-board-import";
import {
  createPortableBoardImportAdapter,
  PortableBoardImportAdapterError,
} from "@/lib/portable-board-import-adapter";
import { runAfterCurrentBoardOwnerCheck } from "@/lib/portable-board-import-auth";
import {
  PortableBoardImportUploadError,
  spoolPortableBoardImportRequest,
} from "@/lib/portable-board-import-upload";
import {
  MAX_PORTABLE_BOARD_IMPORT_BYTES,
  openPortableBoardImportZip,
} from "@/lib/portable-board-import-zip";
import { createTaskAttachmentServiceClient } from "@/lib/supabase/task-attachment-storage";
import { getTaskAttachmentSession } from "@/lib/task-attachment-session";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = { params: Promise<{ slug: string }> };
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function portableImportError(error: unknown): NextResponse {
  if (error instanceof PortableBoardImportUploadError) {
    return json(
      { status: error.kind, message: error.message },
      error.kind === "too_large" ? 413 : error.kind === "invalid" ? 400 : 503,
    );
  }
  if (error instanceof PortableBoardImportAdapterError) {
    const status =
      error.kind === "capacity" || error.kind === "conflict"
        ? 409
        : error.kind === "unavailable" || error.kind === "storage"
          ? 503
          : 400;
    return json({ status: error.kind, message: error.message }, status);
  }
  return json(
    {
      status: "invalid",
      message:
        error instanceof ZodError
          ? "El manifiesto o el contenido del respaldo v2 no cumple el formato permitido."
          : error instanceof Error
            ? error.message
            : "No se pudo leer el respaldo v2.",
    },
    400,
  );
}

function json(body: Record<string, unknown>, status = 200): NextResponse {
  return NextResponse.json(body, {
    status,
    headers: { "Cache-Control": "private, no-store, max-age=0" },
  });
}

export async function POST(
  request: Request,
  { params }: RouteContext,
): Promise<NextResponse> {
  const session = await getTaskAttachmentSession();
  if (!session) return json({ status: "unavailable" }, 404);
  const { slug } = await params;
  const contentType = request.headers
    .get("content-type")
    ?.split(";", 1)[0]
    .trim()
    .toLowerCase();
  if (
    contentType === "application/zip" ||
    contentType === "application/octet-stream"
  ) {
    const operationId = request.headers.get("x-operation-id");
    if (typeof operationId !== "string" || !UUID_PATTERN.test(operationId)) {
      return json(
        {
          status: "invalid",
          message: "El identificador de operación no es válido.",
        },
        400,
      );
    }
    const contentLength = Number(request.headers.get("content-length"));
    if (
      Number.isFinite(contentLength) &&
      contentLength > MAX_PORTABLE_BOARD_IMPORT_BYTES
    ) {
      return json(
        {
          status: "too_large",
          message: "El respaldo supera el límite técnico permitido.",
        },
        413,
      );
    }
    let spool: Awaited<
      ReturnType<typeof spoolPortableBoardImportRequest>
    > | null = null;
    let zip: Awaited<ReturnType<typeof openPortableBoardImportZip>> | null =
      null;
    try {
      const authorization = await runAfterCurrentBoardOwnerCheck(
        { client: session.client, actorId: session.actorId, slug },
        () => spoolPortableBoardImportRequest(request),
      );
      if (authorization.status === "not_owner") {
        return json({ status: "unavailable" }, 404);
      }
      if (authorization.status === "unavailable") {
        return json({ status: "unavailable" }, 503);
      }
      spool = authorization.value;
      zip = await openPortableBoardImportZip(spool.path);
      const adapter = createPortableBoardImportAdapter({
        client: session.client,
        storage: createTaskAttachmentServiceClient,
        actorId: session.actorId,
        slug,
      });
      const preview = await preparePortableBoardImport(
        zip,
        spool.sha256,
        operationId,
        adapter,
      );
      return json(
        preview as unknown as Record<string, unknown>,
        preview.status === "label_conflict" ? 409 : 200,
      );
    } catch (error) {
      return portableImportError(error);
    } finally {
      if (zip) await zip.close();
      if (spool) await spool.cleanup();
    }
  }
  const contentLength = Number(request.headers.get("content-length"));
  if (
    Number.isFinite(contentLength) &&
    contentLength > MAX_LEGACY_IMPORT_REQUEST_BYTES
  ) {
    return json(
      { status: "invalid", message: "El archivo supera el límite permitido." },
      413,
    );
  }

  try {
    const authorization = await runAfterCurrentBoardOwnerCheck(
      { client: session.client, actorId: session.actorId, slug },
      () => readBoundedRequestBody(request),
    );
    if (authorization.status === "not_owner") {
      return json({ status: "unavailable" }, 404);
    }
    if (authorization.status === "unavailable") {
      return json({ status: "unavailable" }, 503);
    }
    const requestBody = authorization.value;
    if (!requestBody) {
      return json(
        {
          status: "invalid",
          message: "El archivo supera el límite permitido.",
        },
        413,
      );
    }
    const formData = await new Response(requestBody, {
      headers: request.headers,
    }).formData();
    const file = formData.get("file");
    const operationId = formData.get("operation_id");
    if (
      !(file instanceof File) ||
      typeof operationId !== "string" ||
      !UUID_PATTERN.test(operationId)
    ) {
      return json(
        { status: "invalid", message: "Selecciona un respaldo v1 válido." },
        400,
      );
    }

    const { document, sourceSha256 } = await readLegacyBoardImportFile(file);
    const { data, error } = await session.client.rpc("prepare_board_import_p", {
      p_slug: slug,
      p_operation_id: operationId,
      p_source_sha256: sourceSha256,
      p_document: document,
    });
    if (error) return json({ status: "error" }, 503);
    const result = data as { status?: unknown } | null;
    if (result?.status === "prepared")
      return json(data as Record<string, unknown>);
    if (result?.status === "conflict")
      return json(data as Record<string, unknown>, 409);
    if (result?.status === "invalid") {
      return json(
        { status: "invalid", message: "El respaldo no cumple el formato v1." },
        400,
      );
    }
    return json({ status: "unavailable" }, 404);
  } catch (error) {
    return json(
      {
        status: "invalid",
        message:
          error instanceof Error
            ? error.message
            : "No se pudo leer el respaldo v1.",
      },
      400,
    );
  }
}
