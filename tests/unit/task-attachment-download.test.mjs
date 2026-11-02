import assert from "node:assert/strict";
import { test } from "node:test";
import {
  isConfirmedMissingTaskAttachmentObject,
  readTaskAttachmentDownloadResponse,
  TASK_ATTACHMENT_MISSING_MESSAGE,
} from "../../src/lib/task-attachment-download.ts";

test("classifies only a confirmed Supabase Storage object 404 as missing", () => {
  assert.equal(
    isConfirmedMissingTaskAttachmentObject({
      __isStorageError: true,
      name: "StorageApiError",
      status: 404,
      statusCode: "404",
    }),
    true,
  );
  assert.equal(
    isConfirmedMissingTaskAttachmentObject({
      __isStorageError: true,
      name: "StorageApiError",
      status: 503,
      statusCode: "503",
    }),
    false,
  );
  assert.equal(
    isConfirmedMissingTaskAttachmentObject({
      name: "Error",
      status: 404,
      message: "network proxy returned 404",
    }),
    false,
  );
});

test("reads a safe missing-object HTTP response without reflecting storage details", async () => {
  const result = await readTaskAttachmentDownloadResponse(
    new Response(
      JSON.stringify({
        status: "missing",
        message: "private storage object key leaked",
      }),
      { status: 410, headers: { "Content-Type": "application/json" } },
    ),
  );

  assert.deepEqual(result, {
    status: "missing",
    message: TASK_ATTACHMENT_MISSING_MESSAGE,
  });
  assert.doesNotMatch(result.message, /storage|attachments\//iu);
});

test("does not expose unknown HTTP or Storage error details to the user", async () => {
  const result = await readTaskAttachmentDownloadResponse(
    new Response(
      JSON.stringify({ status: "error", message: "secret bucket path" }),
      { status: 503, headers: { "Content-Type": "application/json" } },
    ),
  );

  assert.equal(result.status, "failed");
  assert.equal(result.message, "No se pudo descargar el archivo.");
});

test("returns the verified response body for an authorized download", async () => {
  const body = "texto autorizado";
  const result = await readTaskAttachmentDownloadResponse(
    new Response(body, {
      status: 200,
      headers: { "Content-Type": "text/plain" },
    }),
  );

  assert.equal(result.status, "downloaded");
  assert.equal(await result.blob.text(), body);
});
