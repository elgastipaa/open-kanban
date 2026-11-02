import { NextResponse } from "next/server";
import {
  createTaskAttachmentServiceClient,
  TASK_ATTACHMENT_BUCKET,
} from "@/lib/supabase/task-attachment-storage";
import {
  attachmentContentDisposition,
  readTaskAttachmentBody,
  readTaskAttachmentOperationId,
} from "@/lib/task-attachment-http";
import { getTaskAttachmentSession } from "@/lib/task-attachment-session";
import { validateTaskAttachmentPayload } from "@/lib/task-attachment-validation";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = {
  params: Promise<{ slug: string; taskId: string; attachmentId: string }>;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

function json(body: Record<string, unknown>, status = 200): NextResponse {
  return NextResponse.json(body, {
    status,
    headers: { "Cache-Control": "private, no-store, max-age=0" },
  });
}

export async function GET(
  _request: Request,
  { params }: RouteContext,
): Promise<NextResponse> {
  try {
    const session = await getTaskAttachmentSession();
    if (!session) return json({ status: "unavailable" }, 404);
    const { slug, taskId, attachmentId } = await params;
    if (!UUID_PATTERN.test(taskId) || !UUID_PATTERN.test(attachmentId)) {
      return json({ status: "unavailable" }, 404);
    }

    const service = createTaskAttachmentServiceClient();
    const { data: metadataData, error: metadataError } = await service.rpc(
      "resolve_task_attachment_download_p",
      {
        p_actor_id: session.actorId,
        p_slug: slug,
        p_task_id: taskId,
        p_attachment_id: attachmentId,
      },
    );
    const metadata = metadataData as {
      status?: unknown;
      object_key?: unknown;
      file_name?: unknown;
      size_bytes?: unknown;
      sha256?: unknown;
    } | null;
    if (
      metadataError ||
      metadata?.status !== "ok" ||
      metadata.object_key !== `attachments/${attachmentId}` ||
      typeof metadata.file_name !== "string" ||
      typeof metadata.size_bytes !== "number" ||
      typeof metadata.sha256 !== "string"
    ) {
      return json({ status: "unavailable" }, 404);
    }

    const { data: storedObject, error: storageError } = await service.storage
      .from(TASK_ATTACHMENT_BUCKET)
      .download(metadata.object_key);
    if (storageError || !storedObject)
      return json({ status: "unavailable" }, 404);
    const body = await readTaskAttachmentBody(storedObject.stream());
    if (!body.ok) return json({ status: "unavailable" }, 404);
    const validated = validateTaskAttachmentPayload(
      metadata.file_name,
      body.bytes,
    );
    if (
      !validated.ok ||
      validated.sizeBytes !== metadata.size_bytes ||
      validated.sha256 !== metadata.sha256
    ) {
      return json({ status: "unavailable" }, 404);
    }

    const responseBytes = new ArrayBuffer(body.bytes.byteLength);
    new Uint8Array(responseBytes).set(body.bytes);
    return new NextResponse(responseBytes, {
      status: 200,
      headers: {
        "Cache-Control": "private, no-store, max-age=0",
        "Content-Disposition": attachmentContentDisposition(metadata.file_name),
        "Content-Length": String(body.bytes.byteLength),
        "Content-Type": "text/plain; charset=utf-8",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
      },
    });
  } catch {
    return json(
      { status: "error", message: "No se pudo descargar el archivo." },
      503,
    );
  }
}

export async function DELETE(
  request: Request,
  { params }: RouteContext,
): Promise<NextResponse> {
  const operationId = await readTaskAttachmentOperationId(request);
  if (!operationId) return json({ status: "invalid_request" }, 400);
  try {
    const session = await getTaskAttachmentSession();
    if (!session) return json({ status: "unavailable" }, 404);
    const { slug, taskId, attachmentId } = await params;
    if (!UUID_PATTERN.test(taskId) || !UUID_PATTERN.test(attachmentId)) {
      return json({ status: "unavailable" }, 404);
    }
    const service = createTaskAttachmentServiceClient();
    const { data, error } = await service.rpc("delete_task_attachment_p", {
      p_actor_id: session.actorId,
      p_slug: slug,
      p_task_id: taskId,
      p_attachment_id: attachmentId,
      p_operation_id: operationId,
    });
    const result = data as { status?: unknown; expires_at?: unknown } | null;
    if (error || result?.status !== "confirmed") {
      return json({ status: "unavailable" }, 404);
    }
    return json({ status: "confirmed", expires_at: result.expires_at });
  } catch {
    return json(
      { status: "error", message: "No se pudo borrar el archivo." },
      503,
    );
  }
}

export async function PUT(
  request: Request,
  { params }: RouteContext,
): Promise<NextResponse> {
  const operationId = await readTaskAttachmentOperationId(request);
  if (!operationId) return json({ status: "invalid_request" }, 400);
  try {
    const session = await getTaskAttachmentSession();
    if (!session) return json({ status: "unavailable" }, 404);
    const { slug, taskId, attachmentId } = await params;
    if (!UUID_PATTERN.test(taskId) || !UUID_PATTERN.test(attachmentId)) {
      return json({ status: "unavailable" }, 404);
    }
    const service = createTaskAttachmentServiceClient();
    const { data, error } = await service.rpc("restore_task_attachment_p", {
      p_actor_id: session.actorId,
      p_slug: slug,
      p_task_id: taskId,
      p_attachment_id: attachmentId,
      p_operation_id: operationId,
    });
    const result = data as { status?: unknown } | null;
    if (error || result?.status !== "confirmed") {
      return json({ status: "unavailable" }, 404);
    }
    return json({ status: "confirmed", attachment_id: attachmentId });
  } catch {
    return json(
      { status: "error", message: "No se pudo recuperar el archivo." },
      503,
    );
  }
}
