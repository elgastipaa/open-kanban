import { NextResponse } from "next/server";
import {
  MAX_LEGACY_IMPORT_REQUEST_BYTES,
  readBoundedRequestBody,
  readLegacyBoardImportFile,
} from "@/lib/import";
import { getTaskAttachmentSession } from "@/lib/task-attachment-session";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = { params: Promise<{ slug: string }> };
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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
    const requestBody = await readBoundedRequestBody(request);
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
