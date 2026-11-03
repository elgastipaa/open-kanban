import { NextResponse } from "next/server";
import { createTaskAttachmentServiceClient } from "@/lib/supabase/task-attachment-storage";
import {
  parseTaskAttachmentCapacityNotices,
  readCapacityNoticeReadRequest,
} from "@/lib/task-attachment-capacity-notice";
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
    if (!session) return json({ status: "unavailable" }, 404);
    const { data, error } = await createTaskAttachmentServiceClient().rpc(
      "list_my_task_attachment_capacity_notices_p",
      { p_actor_id: session.actorId },
    );
    const notices = !error ? parseTaskAttachmentCapacityNotices(data) : null;
    if (!notices) return json({ status: "unavailable" }, 404);
    return json({ status: "ok", items: notices });
  } catch {
    return json(
      { status: "error", message: "No se pudieron consultar los avisos." },
      503,
    );
  }
}

export async function POST(request: Request): Promise<NextResponse> {
  const threshold = await readCapacityNoticeReadRequest(request);
  if (threshold === null) {
    return json({ status: "invalid_request" }, 400);
  }

  try {
    const session = await getTaskAttachmentSession();
    if (!session) return json({ status: "unavailable" }, 404);
    const { data, error } = await createTaskAttachmentServiceClient().rpc(
      "mark_my_task_attachment_capacity_notice_read_p",
      {
        p_actor_id: session.actorId,
        p_threshold_bytes: threshold,
      },
    );
    const result = data as { status?: unknown } | null;
    if (!error && result?.status === "confirmed") {
      return json({ status: "confirmed" });
    }
    return json({ status: "unavailable" }, 404);
  } catch {
    return json(
      { status: "error", message: "No se pudo actualizar el aviso." },
      503,
    );
  }
}
