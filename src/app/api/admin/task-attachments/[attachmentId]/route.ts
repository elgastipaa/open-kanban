import { NextResponse } from "next/server";
import { createTaskAttachmentServiceClient } from "@/lib/supabase/task-attachment-storage";
import { readTaskAttachmentOperationId } from "@/lib/task-attachment-http";
import { getTaskAttachmentSession } from "@/lib/task-attachment-session";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = { params: Promise<{ attachmentId: string }> };
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

function json(body: Record<string, unknown>, status = 200): NextResponse {
  return NextResponse.json(body, {
    status,
    headers: { "Cache-Control": "private, no-store, max-age=0" },
  });
}

async function updateAttachment(
  request: Request,
  context: RouteContext,
  action: "admin_delete_task_attachment_p" | "admin_restore_task_attachment_p",
): Promise<NextResponse> {
  const operationId = await readTaskAttachmentOperationId(request);
  if (!operationId) return json({ status: "invalid_request" }, 400);
  try {
    const session = await getTaskAttachmentSession();
    if (!session?.isAdmin) return json({ status: "unavailable" }, 404);
    const { attachmentId } = await context.params;
    if (!UUID_PATTERN.test(attachmentId)) {
      return json({ status: "unavailable" }, 404);
    }
    const service = createTaskAttachmentServiceClient();
    const { data, error } = await service.rpc(action, {
      p_actor_id: session.actorId,
      p_attachment_id: attachmentId,
      p_operation_id: operationId,
    });
    const result = data as { status?: unknown; expires_at?: unknown } | null;
    if (error || result?.status !== "confirmed") {
      return json({ status: "unavailable" }, 404);
    }
    return json({
      status: "confirmed",
      attachment_id: attachmentId,
      ...(action === "admin_delete_task_attachment_p"
        ? { expires_at: result.expires_at }
        : {}),
    });
  } catch {
    return json(
      { status: "error", message: "No se pudo actualizar el archivo." },
      503,
    );
  }
}

export async function DELETE(
  request: Request,
  context: RouteContext,
): Promise<NextResponse> {
  return updateAttachment(request, context, "admin_delete_task_attachment_p");
}

export async function PUT(
  request: Request,
  context: RouteContext,
): Promise<NextResponse> {
  return updateAttachment(request, context, "admin_restore_task_attachment_p");
}
