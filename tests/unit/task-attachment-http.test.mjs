import assert from "node:assert/strict";
import { test } from "node:test";
import {
  attachmentContentDisposition,
  readTaskAttachmentBody,
  readTaskAttachmentOperationId,
} from "../../src/lib/task-attachment-http.ts";

function streamChunks(chunks) {
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk);
      controller.close();
    },
  });
}

test("reads exactly the allowed byte limit from a streaming request body", async () => {
  const bytes = new Uint8Array(24_000).fill(0x61);
  const result = await readTaskAttachmentBody(
    streamChunks([bytes.slice(0, 12_000), bytes.slice(12_000)]),
  );

  assert.equal(result.ok, true);
  assert.equal(result.bytes.byteLength, 24_000);
});

test("stops as soon as a request stream crosses the attachment limit", async () => {
  let readAfterLimit = false;
  let chunk = 0;
  const body = new ReadableStream(
    {
      pull(controller) {
        if (chunk === 0) controller.enqueue(new Uint8Array(24_000));
        else if (chunk === 1) controller.enqueue(new Uint8Array([0x61]));
        else {
          readAfterLimit = true;
          controller.close();
        }
        chunk += 1;
      },
    },
    { highWaterMark: 0 },
  );

  const result = await readTaskAttachmentBody(body);
  assert.deepEqual(result, { ok: false, reason: "size" });
  assert.equal(readAfterLimit, false);
});

test("builds attachment-only RFC 5987 disposition without header injection", () => {
  const header = attachmentContentDisposition('reunión "1".md');

  assert.match(header, /^attachment;/);
  assert.match(header, /filename\*=UTF-8''reuni%C3%B3n/);
  assert.doesNotMatch(header, /[\r\n]/);
  assert.doesNotMatch(header, /inline/i);
});

test("parses only a bounded JSON operation UUID and normalizes its casing", async () => {
  const request = new Request("https://openkanban.invalid/attachments/1", {
    method: "DELETE",
    body: JSON.stringify({
      operation_id: "81000000-0000-4000-8000-000000000001",
    }),
  });

  assert.equal(
    await readTaskAttachmentOperationId(request),
    "81000000-0000-4000-8000-000000000001",
  );
  assert.equal(
    await readTaskAttachmentOperationId(
      new Request("https://openkanban.invalid/attachments/1", {
        method: "DELETE",
        body: JSON.stringify({ operation_id: "not-a-uuid" }),
      }),
    ),
    null,
  );
});
