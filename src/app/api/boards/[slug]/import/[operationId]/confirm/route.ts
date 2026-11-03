import { NextResponse } from "next/server";
import { readBoundedRequestBody } from "@/lib/import";
import { MAX_PORTABLE_BOARD_IMPORT_DECISION_BYTES } from "@/lib/portable-board-import-limits";
import { getTaskAttachmentSession } from "@/lib/task-attachment-session";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = { params: Promise<{ slug: string; operationId: string }> };
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const MEMBER_REF_PATTERN = /^member_[0-9a-f]{64}$/;

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
    const bodyBytes = await readBoundedRequestBody(
      request,
      MAX_PORTABLE_BOARD_IMPORT_DECISION_BYTES,
    );
    if (!bodyBytes) return json({ status: "invalid" }, 413);
    const body: unknown = JSON.parse(new TextDecoder().decode(bodyBytes));
    if (typeof body !== "object" || body === null || Array.isArray(body)) {
      return json({ status: "invalid" }, 400);
    }
    const values = body as Record<string, unknown>;
    const hasMemberMappings = Object.hasOwn(values, "member_mappings");
    if (
      Object.keys(values).length !== (hasMemberMappings ? 3 : 2) ||
      typeof values.source_sha256 !== "string" ||
      !SHA256_PATTERN.test(values.source_sha256) ||
      typeof values.expected_content_revision !== "number" ||
      !Number.isSafeInteger(values.expected_content_revision) ||
      values.expected_content_revision < 1
    ) {
      return json({ status: "invalid" }, 400);
    }
    if (
      hasMemberMappings &&
      (!Array.isArray(values.member_mappings) ||
        values.member_mappings.length > 100_000 ||
        !values.member_mappings.every((item) => {
          if (
            typeof item !== "object" ||
            item === null ||
            Array.isArray(item)
          ) {
            return false;
          }
          const mapping = item as Record<string, unknown>;
          return (
            Object.keys(mapping).length === 2 &&
            typeof mapping.source_ref === "string" &&
            MEMBER_REF_PATTERN.test(mapping.source_ref) &&
            (mapping.target_user_id === null ||
              (typeof mapping.target_user_id === "string" &&
                UUID_PATTERN.test(mapping.target_user_id)))
          );
        }))
    ) {
      return json({ status: "invalid" }, 400);
    }
    const rpcName = hasMemberMappings
      ? "confirm_board_import_v2_p"
      : "confirm_board_import_p";
    const rpcArgs: Record<string, unknown> = {
      p_slug: slug,
      p_operation_id: operationId,
      p_expected_content_revision: values.expected_content_revision,
      p_source_sha256: values.source_sha256,
    };
    if (hasMemberMappings) rpcArgs.p_member_mappings = values.member_mappings;
    const { data, error } = await session.client.rpc(rpcName, rpcArgs);
    if (error) return json({ status: "error" }, 503);
    const result = data as { status?: unknown } | null;
    if (result?.status === "confirmed")
      return json(data as Record<string, unknown>);
    if (
      result?.status === "conflict" ||
      result?.status === "capacity" ||
      result?.status === "label_conflict" ||
      result?.status === "member_conflict"
    ) {
      return json(data as Record<string, unknown>, 409);
    }
    if (result?.status === "expired")
      return json(data as Record<string, unknown>, 410);
    return json({ status: "unavailable" }, 404);
  } catch {
    return json({ status: "invalid" }, 400);
  }
}
