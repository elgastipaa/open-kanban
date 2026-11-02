import { timingSafeEqual } from "node:crypto";
import { NextResponse } from "next/server";
import {
  createTaskAttachmentServiceClient,
  removeTaskAttachmentObjectAndConfirmAbsent,
} from "@/lib/supabase/task-attachment-storage";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

function json(body: Record<string, unknown>, status = 200): NextResponse {
  return NextResponse.json(body, {
    status,
    headers: { "Cache-Control": "private, no-store, max-age=0" },
  });
}

function hasValidSecret(request: Request): boolean {
  const expected = process.env.TASK_ATTACHMENT_CLEANUP_SECRET;
  const authorization = request.headers.get("authorization");
  if (!expected || !authorization?.startsWith("Bearer ")) return false;
  const providedBytes = Buffer.from(authorization.slice(7), "utf8");
  const expectedBytes = Buffer.from(expected, "utf8");
  return (
    providedBytes.byteLength === expectedBytes.byteLength &&
    timingSafeEqual(providedBytes, expectedBytes)
  );
}

export async function POST(request: Request): Promise<NextResponse> {
  if (!hasValidSecret(request)) return json({ status: "unavailable" }, 404);
  try {
    const service = createTaskAttachmentServiceClient();
    const { data: expiredExports, error: exportCleanupError } =
      await service.rpc("cleanup_expired_board_export_snapshots_p", {
        p_limit: 100,
      });
    if (
      exportCleanupError ||
      typeof expiredExports !== "number" ||
      !Number.isSafeInteger(expiredExports)
    ) {
      return json({ status: "error" }, 503);
    }

    const leaseId = crypto.randomUUID();
    const { data, error } = await service.rpc(
      "claim_expired_task_attachment_cleanup_p",
      { p_lease_id: leaseId, p_limit: 50 },
    );
    if (error || !Array.isArray(data)) {
      return json({ status: "error" }, 503);
    }

    let purged = 0;
    let pending = 0;
    for (const value of data) {
      if (
        typeof value !== "object" ||
        value === null ||
        !("attachment_id" in value) ||
        typeof value.attachment_id !== "string" ||
        !("object_key" in value) ||
        typeof value.object_key !== "string"
      ) {
        pending += 1;
        continue;
      }
      const objectAbsent = await removeTaskAttachmentObjectAndConfirmAbsent(
        service,
        value.attachment_id,
        value.object_key,
      );

      const { data: confirmationData, error: confirmationError } =
        await service.rpc("confirm_task_attachment_purge_p", {
          p_attachment_id: value.attachment_id,
          p_lease_id: leaseId,
          p_object_absent: objectAbsent,
        });
      const confirmation = confirmationData as { status?: unknown } | null;
      if (confirmationError || !confirmation) {
        pending += 1;
      } else if (confirmation.status === "purged") {
        purged += 1;
      } else {
        pending += 1;
      }
    }

    return json({
      status: "processed",
      export_snapshots_cleaned: expiredExports,
      claimed: data.length,
      purged,
      pending,
    });
  } catch {
    return json({ status: "error" }, 503);
  }
}
