import { timingSafeEqual } from "node:crypto";
import { NextResponse } from "next/server";
import {
  createTaskAttachmentServiceClient,
  TASK_ATTACHMENT_BUCKET,
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
    const storage = service.storage.from(TASK_ATTACHMENT_BUCKET);
    for (const value of data) {
      if (
        typeof value !== "object" ||
        value === null ||
        !("attachment_id" in value) ||
        typeof value.attachment_id !== "string" ||
        !("object_key" in value) ||
        typeof value.object_key !== "string" ||
        !/^attachments\/[0-9a-f-]{36}$/iu.test(value.object_key)
      ) {
        pending += 1;
        continue;
      }
      const parts = value.object_key.split("/");
      const objectName = parts.pop();
      const folder = parts.join("/");
      let objectAbsent = false;
      if (objectName) {
        try {
          const { error: removeError } = await storage.remove([
            value.object_key,
          ]);
          if (!removeError) {
            const { data: objects, error: listError } = await storage.list(
              folder,
              {
                limit: 2,
                search: objectName,
              },
            );
            objectAbsent =
              !listError &&
              !objects.some((object) => object.name === objectName);
          }
        } catch {
          objectAbsent = false;
        }
      }

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

    return json({ status: "processed", claimed: data.length, purged, pending });
  } catch {
    return json({ status: "error" }, 503);
  }
}
