import { NextResponse } from "next/server";
import {
  createTaskAttachmentServiceClient,
  removeTaskAttachmentObjectAndConfirmAbsent,
  TASK_ATTACHMENT_BUCKET,
} from "@/lib/supabase/task-attachment-storage";
import { readTaskAttachmentBody } from "@/lib/task-attachment-http";
import { getTaskAttachmentSession } from "@/lib/task-attachment-session";
import { validateTaskAttachmentPayload } from "@/lib/task-attachment-validation";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = { params: Promise<{ slug: string; taskId: string }> };

function json(body: Record<string, unknown>, status = 200): NextResponse {
  return NextResponse.json(body, {
    status,
    headers: { "Cache-Control": "private, no-store, max-age=0" },
  });
}

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

function decodeFileName(header: string | null): string | null {
  if (!header || header.length > 720) return null;
  try {
    return decodeURIComponent(header);
  } catch {
    return null;
  }
}

function uploadValidationMessage(reason: string): string {
  switch (reason) {
    case "size":
      return "El archivo no puede superar 24.000 bytes.";
    case "extension":
      return "Solo se admiten archivos .txt o .md.";
    case "encoding":
    case "binary":
      return "El archivo debe ser texto UTF-8 válido.";
    case "empty":
      return "El archivo está vacío.";
    default:
      return "El nombre del archivo no es válido.";
  }
}

async function cleanupReservation(
  service: ReturnType<typeof createTaskAttachmentServiceClient>,
  attachmentId: string,
): Promise<void> {
  const leaseId = crypto.randomUUID();
  const { data: claimData, error: claimError } = await service.rpc(
    "begin_task_attachment_cleanup_p",
    { p_attachment_id: attachmentId, p_lease_id: leaseId },
  );
  const claim = claimData as { status?: unknown; object_key?: unknown } | null;
  if (
    claimError ||
    claim?.status !== "claimed" ||
    typeof claim.object_key !== "string"
  ) {
    return;
  }

  const objectAbsent = await removeTaskAttachmentObjectAndConfirmAbsent(
    service,
    attachmentId,
    claim.object_key,
  );
  await service.rpc("confirm_task_attachment_purge_p", {
    p_attachment_id: attachmentId,
    p_lease_id: leaseId,
    p_object_absent: objectAbsent,
  });
}

export async function GET(
  _request: Request,
  { params }: RouteContext,
): Promise<NextResponse> {
  try {
    const session = await getTaskAttachmentSession();
    if (!session) return json({ status: "unavailable" }, 404);
    const { slug, taskId } = await params;
    if (!UUID_PATTERN.test(taskId)) return json({ status: "unavailable" }, 404);
    const { data, error } = await session.client.rpc(
      "list_task_attachments_p",
      {
        p_slug: slug,
        p_task_id: taskId,
      },
    );
    if (error || !data || typeof data !== "object" || !("status" in data)) {
      return json({ status: "unavailable" }, 404);
    }
    if (data.status !== "ok") return json({ status: "unavailable" }, 404);
    return json(data as Record<string, unknown>);
  } catch {
    return json(
      { status: "error", message: "No se pudieron consultar los archivos." },
      503,
    );
  }
}

export async function POST(
  request: Request,
  { params }: RouteContext,
): Promise<NextResponse> {
  const contentLength = request.headers.get("content-length");
  if (
    contentLength !== null &&
    (!/^\d+$/u.test(contentLength) || Number(contentLength) > 24_000)
  ) {
    return json(
      {
        status: "too_large",
        message: "El archivo no puede superar 24.000 bytes.",
      },
      413,
    );
  }

  const operationId = request.headers.get("idempotency-key");
  const fileName = decodeFileName(request.headers.get("x-file-name"));
  if (!operationId || !UUID_PATTERN.test(operationId) || !fileName) {
    return json({ status: "invalid_request" }, 400);
  }

  const body = await readTaskAttachmentBody(request.body);
  if (!body.ok) {
    return json(
      {
        status: "too_large",
        message: "El archivo no puede superar 24.000 bytes.",
      },
      413,
    );
  }
  const validated = validateTaskAttachmentPayload(fileName, body.bytes);
  if (!validated.ok) {
    return json(
      {
        status: "invalid_file",
        message: uploadValidationMessage(validated.reason),
      },
      validated.reason === "size" ? 413 : 400,
    );
  }

  let attachmentId: string | null = null;
  try {
    const session = await getTaskAttachmentSession();
    if (!session) return json({ status: "unavailable" }, 404);
    const { slug, taskId } = await params;
    if (!UUID_PATTERN.test(taskId)) return json({ status: "unavailable" }, 404);
    const service = createTaskAttachmentServiceClient();
    const { data, error } = await service.rpc("reserve_task_attachment_p", {
      p_actor_id: session.actorId,
      p_operation_id: operationId.toLowerCase(),
      p_slug: slug,
      p_task_id: taskId,
      p_file_name: validated.fileName,
      p_size_bytes: validated.sizeBytes,
      p_sha256: validated.sha256,
    });
    const reservation = data as {
      status?: unknown;
      attachment_id?: unknown;
    } | null;
    if (error || !reservation || typeof reservation.status !== "string") {
      return json(
        {
          status: "error",
          message: "No se pudo reservar el espacio. Inténtalo de nuevo.",
        },
        503,
      );
    }
    if (reservation.status === "confirmed") {
      return json({
        status: "confirmed",
        attachment_id: reservation.attachment_id,
      });
    }
    if (
      reservation.status !== "reserved" ||
      typeof reservation.attachment_id !== "string"
    ) {
      if (reservation.status === "quota") {
        return json(
          {
            status: "quota",
            message: "No hay espacio disponible para este archivo.",
          },
          409,
        );
      }
      if (reservation.status === "task_limit") {
        return json(
          {
            status: "task_limit",
            message: "Esta tarea ya alcanzó el límite de 20 archivos.",
          },
          409,
        );
      }
      if (
        reservation.status === "reservation_limit" ||
        reservation.status === "instance_busy" ||
        reservation.status === "rate_limited"
      ) {
        return json(
          {
            status: "retryable",
            message: "Hay otras cargas en curso. Inténtalo de nuevo.",
          },
          429,
        );
      }
      return json({ status: "unavailable" }, 404);
    }

    attachmentId = reservation.attachment_id;
    const objectKey = `attachments/${attachmentId}`;
    const storage = service.storage.from(TASK_ATTACHMENT_BUCKET);
    await storage.upload(objectKey, body.bytes.slice().buffer, {
      cacheControl: "0",
      contentType: "text/plain",
      upsert: false,
    });

    const { data: storedObject, error: storageError } =
      await storage.download(objectKey);
    if (storageError || !storedObject) {
      await cleanupReservation(service, attachmentId);
      return json(
        {
          status: "error",
          message: "No se pudo verificar el archivo cargado.",
        },
        503,
      );
    }
    const storedBody = await readTaskAttachmentBody(storedObject.stream());
    if (!storedBody.ok) {
      await cleanupReservation(service, attachmentId);
      return json(
        {
          status: "error",
          message: "No se pudo verificar el archivo cargado.",
        },
        503,
      );
    }
    const storedValidation = validateTaskAttachmentPayload(
      validated.fileName,
      storedBody.bytes,
    );
    if (
      !storedValidation.ok ||
      storedValidation.sizeBytes !== validated.sizeBytes ||
      storedValidation.sha256 !== validated.sha256
    ) {
      await cleanupReservation(service, attachmentId);
      return json(
        {
          status: "error",
          message: "No se pudo verificar el archivo cargado.",
        },
        503,
      );
    }

    const { data: publishedData, error: publishError } = await service.rpc(
      "publish_task_attachment_p",
      {
        p_actor_id: session.actorId,
        p_slug: slug,
        p_task_id: taskId,
        p_attachment_id: attachmentId,
        p_operation_id: operationId.toLowerCase(),
        p_verified_size_bytes: storedValidation.sizeBytes,
        p_verified_sha256: storedValidation.sha256,
      },
    );
    const publication = publishedData as { status?: unknown } | null;
    if (publishError || publication?.status !== "confirmed") {
      await cleanupReservation(service, attachmentId);
      return json({ status: "unavailable" }, 404);
    }

    return json({ status: "confirmed", attachment_id: attachmentId });
  } catch {
    if (attachmentId) {
      try {
        await cleanupReservation(
          createTaskAttachmentServiceClient(),
          attachmentId,
        );
      } catch {
        // The reservation remains charged until the cleanup job confirms absence.
      }
    }
    return json(
      {
        status: "error",
        message:
          "No se pudo confirmar el archivo. Revisa el listado antes de volver a cargarlo.",
      },
      503,
    );
  }
}
