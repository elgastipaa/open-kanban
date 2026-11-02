import { NextResponse } from "next/server";
import { readBoundedRequestBody } from "@/lib/import";
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

export async function GET(
  _request: Request,
  { params }: RouteContext,
): Promise<NextResponse> {
  const session = await getTaskAttachmentSession();
  if (!session) return json({ status: "unavailable" }, 404);
  const { slug } = await params;
  try {
    const { data, error } = await session.client.rpc(
      "list_board_import_recoveries_p",
      { p_slug: slug },
    );
    if (error) return json({ status: "error" }, 503);
    const result = data as { status?: unknown } | null;
    if (result?.status === "available")
      return json(data as Record<string, unknown>);
    return json({ status: "unavailable" }, 404);
  } catch {
    return json({ status: "error" }, 503);
  }
}

export async function POST(
  request: Request,
  { params }: RouteContext,
): Promise<NextResponse> {
  const session = await getTaskAttachmentSession();
  if (!session) return json({ status: "unavailable" }, 404);
  const { slug } = await params;
  try {
    const bodyBytes = await readBoundedRequestBody(request, 4096);
    if (!bodyBytes) return json({ status: "invalid" }, 413);
    const body: unknown = JSON.parse(new TextDecoder().decode(bodyBytes));
    if (typeof body !== "object" || body === null || Array.isArray(body)) {
      return json({ status: "invalid" }, 400);
    }
    const values = body as Record<string, unknown>;
    if (
      typeof values.operation_id !== "string" ||
      !UUID_PATTERN.test(values.operation_id) ||
      typeof values.generation_id !== "string" ||
      !UUID_PATTERN.test(values.generation_id)
    ) {
      return json({ status: "invalid" }, 400);
    }
    const { data, error } = await session.client.rpc(
      "prepare_board_import_restore_p",
      {
        p_slug: slug,
        p_operation_id: values.operation_id,
        p_generation_id: values.generation_id,
      },
    );
    if (error) return json({ status: "error" }, 503);
    const result = data as { status?: unknown } | null;
    if (result?.status === "prepared")
      return json(data as Record<string, unknown>);
    if (result?.status === "expired")
      return json(data as Record<string, unknown>, 410);
    if (result?.status === "conflict")
      return json(data as Record<string, unknown>, 409);
    return json({ status: "unavailable" }, 404);
  } catch {
    return json({ status: "invalid" }, 400);
  }
}
