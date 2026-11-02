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

test("confirms a missing object after a 404 when the bucket exists despite stale object metadata", async () => {
  const object404 = {
    __isStorageError: true,
    name: "StorageApiError",
    status: 404,
    statusCode: "NoSuchKey",
    message: "Object not found",
  };
  const staleMetadata = [{ name: "id-1" }];
  let bucketLookups = 0;
  let listCalls = 0;
  const storage = {
    async getBucket(bucketId) {
      bucketLookups += 1;
      return { data: { id: bucketId }, error: null };
    },
    from() {
      return {
        async list() {
          listCalls += 1;
          return { data: staleMetadata, error: null };
        },
      };
    },
  };

  assert.equal(
    staleMetadata.some((object) => object.name === "id-1"),
    true,
  );
  assert.equal(
    await isConfirmedMissingTaskAttachmentObject(
      object404,
      "task-attachments",
      storage,
    ),
    true,
  );
  assert.equal(bucketLookups, 1);
  assert.equal(listCalls, 0);
});

test("fails closed when the bucket lookup is absent, invalid, rejected, or times out", async () => {
  const object404 = {
    __isStorageError: true,
    name: "StorageApiError",
    status: 404,
    statusCode: "404",
    message: "Object not found",
  };
  const bucket404 = {
    __isStorageError: true,
    name: "StorageApiError",
    status: 404,
    statusCode: "NoSuchBucket",
    message: "Bucket not found",
  };
  const objectStorage = {
    __isStorageError: true,
    name: "StorageApiError",
    status: 503,
    statusCode: "503",
  };

  assert.equal(
    await isConfirmedMissingTaskAttachmentObject(
      bucket404,
      "task-attachments",
      { getBucket: async () => ({ data: null, error: bucket404 }) },
    ),
    false,
  );
  assert.equal(
    await isConfirmedMissingTaskAttachmentObject(
      object404,
      "task-attachments",
      { getBucket: async () => ({ data: null, error: bucket404 }) },
    ),
    false,
  );
  assert.equal(
    await isConfirmedMissingTaskAttachmentObject(
      object404,
      "task-attachments",
      {
        getBucket: async () => ({
          data: { id: "another-bucket" },
          error: null,
        }),
      },
    ),
    false,
  );
  assert.equal(
    await isConfirmedMissingTaskAttachmentObject(
      object404,
      "task-attachments",
      { getBucket: async () => ({ data: null, error: objectStorage }) },
    ),
    false,
  );
  assert.equal(
    await isConfirmedMissingTaskAttachmentObject(
      object404,
      "task-attachments",
      {
        async getBucket() {
          throw new Error("bucket lookup failed");
        },
      },
    ),
    false,
  );
  assert.equal(
    await isConfirmedMissingTaskAttachmentObject(
      { name: "Error", status: 404, message: "proxy returned 404" },
      "task-attachments",
      {
        getBucket: async () => ({
          data: { id: "task-attachments" },
          error: null,
        }),
      },
    ),
    false,
  );
  assert.equal(
    await isConfirmedMissingTaskAttachmentObject(
      { ...object404, status: 503 },
      "task-attachments",
      {
        getBucket: async () => ({
          data: { id: "task-attachments" },
          error: null,
        }),
      },
    ),
    false,
  );
  assert.equal(
    await isConfirmedMissingTaskAttachmentObject(
      object404,
      "task-attachments",
      { getBucket: () => new Promise(() => {}) },
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
