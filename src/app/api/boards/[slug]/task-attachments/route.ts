import { NextResponse } from "next/server";
import { createTaskAttachmentServiceClient } from "@/lib/supabase/task-attachment-storage";
import {
  parseBoardTaskAttachmentStoragePage,
  parseCompletedTaskAttachmentCleanupPreview,
  readBoardTaskAttachmentCleanupRequest,
  readBoardTaskAttachmentCursor,
} from "@/lib/task-attachment-board-cleanup";
import { getTaskAttachmentSession } from "@/lib/task-attachment-session";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = { params: Promise<{ slug: string }> };

function json(body: Record<string, unknown>, status = 200): NextResponse {
  return NextResponse.json(body, {
    status,
    headers: { "Cache-Control": "private, no-store, max-age=0" },
  });
}

export async function GET(
  request: Request,
  { params }: RouteContext,
): Promise<NextResponse> {
  try {
    const session = await getTaskAttachmentSession();
    if (!session) return json({ status: "unavailable" }, 404);
    const { slug } = await params;
    const parsedCursor = readBoardTaskAttachmentCursor(
      new URL(request.url).searchParams,
    );
    if (!parsedCursor.ok) return json({ status: "invalid_cursor" }, 400);

    const { data, error } = await createTaskAttachmentServiceClient().rpc(
      "list_board_task_attachment_storage_p",
      {
        p_actor_id: session.actorId,
        p_slug: slug,
        p_limit: 100,
        p_cursor_created_at: parsedCursor.cursor?.createdAt ?? null,
        p_cursor_attachment_id: parsedCursor.cursor?.attachmentId ?? null,
      },
    );
    const page = !error ? parseBoardTaskAttachmentStoragePage(data) : null;
    if (!page) return json({ status: "unavailable" }, 404);
    return json({ status: "ok", ...page });
  } catch {
    return json(
      { status: "error", message: "No se pudo consultar el almacenamiento." },
      503,
    );
  }
}

export async function POST(
  request: Request,
  { params }: RouteContext,
): Promise<NextResponse> {
  const body = await readBoardTaskAttachmentCleanupRequest(request);
  if (!body) return json({ status: "invalid_request" }, 400);

  try {
    const session = await getTaskAttachmentSession();
    if (!session) return json({ status: "unavailable" }, 404);
    const { slug } = await params;
    const service = createTaskAttachmentServiceClient();
    if (body.action === "preview") {
      const { data, error } = await service.rpc(
        "preview_completed_task_attachment_cleanup_p",
        {
          p_actor_id: session.actorId,
          p_slug: slug,
          p_attachment_id: body.attachment_id,
        },
      );
      if (error) {
        return json(
          {
            status: "error",
            message: "No se pudo preparar la vista previa. Inténtalo de nuevo.",
          },
          503,
        );
      }
      const preview = parseCompletedTaskAttachmentCleanupPreview(data);
      if (!preview) return json({ status: "unavailable" }, 409);
      return json({ status: "preview", item: preview.item });
    }

    const { data, error } = await service.rpc(
      "cleanup_completed_task_attachment_p",
      {
        p_actor_id: session.actorId,
        p_slug: slug,
        p_attachment_id: body.attachment_id,
        p_operation_id: body.operation_id,
      },
    );
    const result = data as {
      status?: unknown;
      attachment_id?: unknown;
      expires_at?: unknown;
    } | null;
    if (
      !error &&
      result?.status === "confirmed" &&
      result.attachment_id === body.attachment_id
    ) {
      return json({
        status: "confirmed",
        attachment_id: body.attachment_id,
        ...(typeof result.expires_at === "string" &&
        Number.isFinite(Date.parse(result.expires_at))
          ? { expires_at: result.expires_at }
          : {}),
      });
    }
    if (!error && result?.status === "unavailable") {
      return json({ status: "unavailable" }, 409);
    }
    return json(
      {
        status: "error",
        message:
          "No se pudo confirmar la limpieza. Revisa el listado y vuelve a intentar con la misma operación.",
      },
      503,
    );
  } catch {
    return json(
      {
        status: "error",
        message:
          "No se pudo confirmar la limpieza. Revisa el listado y vuelve a intentar con la misma operación.",
      },
      503,
    );
  }
}
