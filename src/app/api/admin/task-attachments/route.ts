import { NextResponse } from "next/server";
import { createTaskAttachmentServiceClient } from "@/lib/supabase/task-attachment-storage";
import { readAdminTaskAttachmentCursor } from "@/lib/task-attachment-admin-cursor";
import { getTaskAttachmentSession } from "@/lib/task-attachment-session";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";
function json(body: Record<string, unknown>, status = 200): NextResponse {
  return NextResponse.json(body, {
    status,
    headers: { "Cache-Control": "private, no-store, max-age=0" },
  });
}

export async function GET(request: Request): Promise<NextResponse> {
  try {
    const session = await getTaskAttachmentSession();
    if (!session?.isAdmin) return json({ status: "unavailable" }, 404);
    const search = new URL(request.url).searchParams;
    const parsedCursor = readAdminTaskAttachmentCursor(search);
    if (!parsedCursor.ok) {
      return json({ status: "invalid_cursor" }, 400);
    }
    const cursorCreatedAt = parsedCursor.cursor?.createdAt ?? null;
    const cursorAttachmentId = parsedCursor.cursor?.attachmentId ?? null;
    const service = createTaskAttachmentServiceClient();
    const [summaryResult, itemsResult] = await Promise.all([
      service.rpc("admin_task_attachment_storage_summary_p", {
        p_actor_id: session.actorId,
      }),
      service.rpc("list_admin_task_attachment_cleanup_p", {
        p_actor_id: session.actorId,
        p_limit: 100,
        p_cursor_created_at: cursorCreatedAt,
        p_cursor_attachment_id: cursorAttachmentId,
      }),
    ]);
    const summary = summaryResult.data as {
      status?: unknown;
      limit_bytes?: unknown;
    } | null;
    const items = itemsResult.data as {
      status?: unknown;
      items?: unknown;
      has_more?: unknown;
      next_cursor?: unknown;
    } | null;
    if (
      summaryResult.error ||
      itemsResult.error ||
      summary?.status !== "ok" ||
      items?.status !== "ok" ||
      !Array.isArray(items.items) ||
      typeof items.has_more !== "boolean" ||
      (items.has_more &&
        (typeof items.next_cursor !== "object" ||
          items.next_cursor === null ||
          typeof (items.next_cursor as Record<string, unknown>).created_at !==
            "string" ||
          typeof (items.next_cursor as Record<string, unknown>)
            .attachment_id !== "string"))
    ) {
      return json(
        { status: "error", message: "No se pudo consultar el almacenamiento." },
        503,
      );
    }
    return json({
      status: "ok",
      summary,
      items: items.items,
      has_more: items.has_more,
      next_cursor: items.next_cursor ?? null,
    });
  } catch {
    return json(
      { status: "error", message: "No se pudo consultar el almacenamiento." },
      503,
    );
  }
}
