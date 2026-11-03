import { NextResponse } from "next/server";
import { readBoundedRequestBody } from "@/lib/import";
import { getTaskAttachmentSession } from "@/lib/task-attachment-session";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = {
  params: Promise<{ slug: string; operationId: string }>;
};
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
  const { slug, operationId } = await params;
  if (!UUID_PATTERN.test(operationId))
    return json({ status: "unavailable" }, 404);
  try {
    const bodyBytes = await readBoundedRequestBody(request, 1024);
    if (!bodyBytes) return json({ status: "invalid" }, 413);
    const body: unknown = JSON.parse(new TextDecoder().decode(bodyBytes));
    if (typeof body !== "object" || body === null || Array.isArray(body)) {
      return json({ status: "invalid" }, 400);
    }
    const values = body as Record<string, unknown>;
    if (
      Object.keys(values).length !== 2 ||
      typeof values.generation_id !== "string" ||
      !UUID_PATTERN.test(values.generation_id) ||
      typeof values.expected_content_revision !== "number" ||
      !Number.isSafeInteger(values.expected_content_revision) ||
      values.expected_content_revision < 1
    ) {
      return json({ status: "invalid" }, 400);
    }
    const { data, error } = await session.client.rpc(
      "confirm_board_import_restore_p",
      {
        p_slug: slug,
        p_generation_id: values.generation_id,
        p_operation_id: operationId,
        p_expected_content_revision: values.expected_content_revision,
      },
    );
    if (error) return json({ status: "error" }, 503);
    const result = data as { status?: unknown } | null;
    if (result?.status === "confirmed")
      return json(data as Record<string, unknown>);
    if (result?.status === "conflict" || result?.status === "capacity")
      return json(data as Record<string, unknown>, 409);
    if (
      result?.status === "expired" ||
      result?.status === "metadata_unavailable"
    )
      return json(data as Record<string, unknown>, 410);
    return json({ status: "unavailable" }, 404);
  } catch {
    return json({ status: "invalid" }, 400);
  }
}
