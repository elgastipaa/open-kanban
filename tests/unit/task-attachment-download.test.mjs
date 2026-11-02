import assert from "node:assert/strict";
import { test } from "node:test";
import {
  isConfirmedMissingTaskAttachmentObject,
  isTaskAttachmentObjectAbsentFromCompleteInventory,
  readTaskAttachmentDownloadResponse,
  TASK_ATTACHMENT_MISSING_MESSAGE,
} from "../../src/lib/task-attachment-download.ts";

test("only a complete exact-key inventory confirms object absence", () => {
  assert.equal(
    isTaskAttachmentObjectAbsentFromCompleteInventory(
      [],
      null,
      "attachments/id-1",
    ),
    true,
  );
  assert.equal(
    isTaskAttachmentObjectAbsentFromCompleteInventory(
      [{ name: "id-1" }],
      null,
      "attachments/id-1",
    ),
    false,
  );
  assert.equal(
    isTaskAttachmentObjectAbsentFromCompleteInventory(
      [{ name: "id-1-suffix" }],
      null,
      "attachments/id-1",
    ),
    true,
  );
  assert.equal(
    isTaskAttachmentObjectAbsentFromCompleteInventory(
      [{ name: "id-1-suffix" }, { name: "other-id-1" }],
      null,
      "attachments/id-1",
    ),
    false,
  );
  assert.equal(
    isTaskAttachmentObjectAbsentFromCompleteInventory(
      [],
      { message: "Bucket not found" },
      "attachments/id-1",
    ),
    false,
  );
  assert.equal(
    isTaskAttachmentObjectAbsentFromCompleteInventory(
      [{ name: null }],
      null,
      "attachments/id-1",
    ),
    false,
  );
});

test("confirms a missing object only after a successful exact-key inventory", () => {
  const object404 = {
    __isStorageError: true,
    name: "StorageApiError",
    status: 404,
    statusCode: "NoSuchKey",
    message: "Object not found",
  };
  const bucket404 = {
    __isStorageError: true,
    name: "StorageApiError",
    status: 404,
    statusCode: "NoSuchBucket",
    message: "Bucket not found",
  };
  const sdkHttpOnly404 = { ...object404, statusCode: "404" };

  assert.equal(
    isConfirmedMissingTaskAttachmentObject(
      object404,
      [],
      null,
      "attachments/id-1",
    ),
    true,
  );
  assert.equal(
    isConfirmedMissingTaskAttachmentObject(
      sdkHttpOnly404,
      [],
      null,
      "attachments/id-1",
    ),
    true,
  );
  assert.equal(
    isConfirmedMissingTaskAttachmentObject(
      bucket404,
      null,
      bucket404,
      "attachments/id-1",
    ),
    false,
  );
  assert.equal(
    isConfirmedMissingTaskAttachmentObject(
      { ...bucket404, statusCode: "404" },
      [],
      null,
      "attachments/id-1",
    ),
    false,
  );
  assert.equal(
    isConfirmedMissingTaskAttachmentObject(
      {
        name: "Error",
        status: 404,
        message: "network proxy returned 404",
      },
      [],
      null,
      "attachments/id-1",
    ),
    false,
  );
  assert.equal(
    isConfirmedMissingTaskAttachmentObject(
      object404,
      [{ name: "id-1" }],
      null,
      "attachments/id-1",
    ),
    false,
  );
  assert.equal(
    isConfirmedMissingTaskAttachmentObject(
      object404,
      null,
      null,
      "attachments/id-1",
    ),
    false,
  );
  assert.equal(
    isConfirmedMissingTaskAttachmentObject(
      { ...object404, status: 503 },
      [],
      null,
      "attachments/id-1",
    ),
    false,
  );
  assert.equal(
    isConfirmedMissingTaskAttachmentObject(
      object404,
      [{ name: "id-1-other" }],
      null,
      "attachments/id-1",
    ),
    true,
  );
  assert.equal(
    isConfirmedMissingTaskAttachmentObject(
      object404,
      [{ name: "id-1-other" }, { name: "another-id-1" }],
      null,
      "attachments/id-1",
    ),
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
