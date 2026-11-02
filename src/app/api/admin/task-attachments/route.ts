import { NextResponse } from "next/server";
import { createTaskAttachmentServiceClient } from "@/lib/supabase/task-attachment-storage";
import { getTaskAttachmentSession } from "@/lib/task-attachment-session";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

function json(body: Record<string, unknown>, status = 200): NextResponse {
  return NextResponse.json(body, {
    status,
    headers: { "Cache-Control": "private, no-store, max-age=0" },
  });
}

export async function GET(): Promise<NextResponse> {
  try {
    const session = await getTaskAttachmentSession();
    if (!session?.isAdmin) return json({ status: "unavailable" }, 404);
    const service = createTaskAttachmentServiceClient();
    const [summaryResult, itemsResult] = await Promise.all([
      service.rpc("admin_task_attachment_storage_summary_p", {
        p_actor_id: session.actorId,
      }),
      service.rpc("list_admin_task_attachment_cleanup_p", {
        p_actor_id: session.actorId,
        p_limit: 100,
      }),
    ]);
    const summary = summaryResult.data as {
      status?: unknown;
      limit_bytes?: unknown;
    } | null;
    const items = itemsResult.data as {
      status?: unknown;
      items?: unknown;
    } | null;
    if (
      summaryResult.error ||
      itemsResult.error ||
      summary?.status !== "ok" ||
      items?.status !== "ok" ||
      !Array.isArray(items.items)
    ) {
      return json(
        { status: "error", message: "No se pudo consultar el almacenamiento." },
        503,
      );
    }
    return json({ status: "ok", summary, items: items.items });
  } catch {
    return json(
      { status: "error", message: "No se pudo consultar el almacenamiento." },
      503,
    );
  }
}
