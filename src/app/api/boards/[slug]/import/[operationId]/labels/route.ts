import { NextResponse } from "next/server";
import { readBoundedRequestBody } from "@/lib/import";
import { MAX_PORTABLE_BOARD_IMPORT_DECISION_BYTES } from "@/lib/portable-board-import-limits";
import { getTaskAttachmentSession } from "@/lib/task-attachment-session";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = { params: Promise<{ slug: string; operationId: string }> };
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const LABEL_REF_PATTERN = /^label_[0-9a-f]{64}$/;
const MEMBER_REF_PATTERN = /^member_[0-9a-f]{64}$/;

function json(body: Record<string, unknown>, status = 200): NextResponse {
  return NextResponse.json(body, {
    status,
    headers: { "Cache-Control": "private, no-store, max-age=0" },
  });
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
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
    const value = body as Record<string, unknown>;
    if (
      Object.keys(value).length !== 2 ||
      !Array.isArray(value.label_resolutions) ||
      value.label_resolutions.length > 100_000 ||
      !Array.isArray(value.member_mappings) ||
      value.member_mappings.length > 100_000 ||
      !value.label_resolutions.every((item) => {
        if (typeof item !== "object" || item === null || Array.isArray(item)) {
          return false;
        }
        const resolution = item as Record<string, unknown>;
        return (
          Object.keys(resolution).length === 2 &&
          typeof resolution.source_ref === "string" &&
          LABEL_REF_PATTERN.test(resolution.source_ref) &&
          typeof resolution.name === "string" &&
          resolution.name.length >= 1 &&
          resolution.name.length <= 40 &&
          resolution.name.trim() === resolution.name
        );
      }) ||
      !value.member_mappings.every((item) => {
        if (typeof item !== "object" || item === null || Array.isArray(item)) {
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
      })
    ) {
      return json({ status: "invalid" }, 400);
    }
    const { data, error } = await session.client.rpc(
      "set_board_import_v2_label_resolutions_p",
      {
        p_slug: slug,
        p_operation_id: operationId,
        p_resolutions: value.label_resolutions,
        p_member_mappings: value.member_mappings,
      },
    );
    if (error) return json({ status: "error" }, 503);
    const result = asRecord(data);
    if (result?.status === "label_conflict") {
      const preview = asRecord(result.preview);
      return json(
        {
          ...(preview ?? {}),
          status: "label_conflict",
          label_conflicts: result.label_conflicts,
        },
        409,
      );
    }
    if (result?.status === "member_conflict") {
      return json(
        {
          ...(asRecord(result.preview) ?? {}),
          status: "member_conflict",
        },
        409,
      );
    }
    if (result?.status === "invalid") return json({ status: "invalid" }, 400);
    if (result?.status === "saved") {
      const { data: preview, error: finalizeError } = await session.client.rpc(
        "finalize_board_import_v2_p",
        { p_slug: slug, p_operation_id: operationId },
      );
      if (finalizeError) return json({ status: "error" }, 503);
      const finalized = asRecord(preview);
      if (finalized?.status === "prepared")
        return json(preview as Record<string, unknown>);
      if (finalized?.status === "label_conflict")
        return json(preview as Record<string, unknown>, 409);
      if (finalized?.status === "member_conflict")
        return json(preview as Record<string, unknown>, 409);
    }
    return json({ status: "unavailable" }, 404);
  } catch {
    return json({ status: "invalid" }, 400);
  }
}
