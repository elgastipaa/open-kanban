import { NextResponse } from "next/server";
import { createTaskAttachmentServiceClient } from "@/lib/supabase/task-attachment-storage";
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

export async function POST(
  _request: Request,
  { params }: RouteContext,
): Promise<NextResponse> {
  const session = await getTaskAttachmentSession();
  if (!session) return json({ status: "unavailable" }, 404);

  const { slug } = await params;
  try {
    const service = createTaskAttachmentServiceClient();
    const { data, error } = await service.rpc(
      "create_board_export_snapshot_p",
      {
        p_actor_id: session.actorId,
        p_board_slug: slug,
      },
    );
    const result = data as { status?: unknown; export_id?: unknown } | null;
    if (
      error ||
      result?.status !== "created" ||
      typeof result.export_id !== "string"
    ) {
      return json({ status: "unavailable" }, 404);
    }
    return json({ status: "ready", export_id: result.export_id }, 201);
  } catch {
    return json({ status: "error" }, 503);
  }
}
