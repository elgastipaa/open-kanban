import assert from "node:assert/strict";
import { test } from "node:test";
import {
  parseTaskAttachmentCapacityNotices,
  readCapacityNoticeReadRequest,
  taskAttachmentCapacityNoticeMessage,
} from "../../src/lib/task-attachment-capacity-notice.ts";

const noticeDate = "2026-11-02T18:21:57.668278+00:00";

test("parses only aggregate capacity notice fields and preserves the threshold", () => {
  const parsed = parseTaskAttachmentCapacityNotices({
    status: "ok",
    items: [
      { threshold_bytes: 160000000, last_notified_at: noticeDate },
      {
        threshold_bytes: 200000000,
        last_notified_at: noticeDate,
        file_name: "private.md",
      },
    ],
  });
  assert.deepEqual(parsed, [
    { threshold_bytes: 160000000, last_notified_at: noticeDate },
    { threshold_bytes: 200000000, last_notified_at: noticeDate },
  ]);
});

test("rejects invalid or duplicated threshold notices", () => {
  assert.equal(
    parseTaskAttachmentCapacityNotices({
      status: "ok",
      items: [{ threshold_bytes: 80000000, last_notified_at: noticeDate }],
    }),
    null,
  );
  assert.equal(
    parseTaskAttachmentCapacityNotices({
      status: "ok",
      items: [
        { threshold_bytes: 160000000, last_notified_at: noticeDate },
        { threshold_bytes: 160000000, last_notified_at: noticeDate },
      ],
    }),
    null,
  );
});

test("capacity messages explain the shared threshold and delayed quota release", () => {
  assert.match(
    taskAttachmentCapacityNoticeMessage({
      threshold_bytes: 160000000,
      last_notified_at: noticeDate,
    }),
    /80 %.*160 MB.*200 MB.*purga/iu,
  );
  assert.match(
    taskAttachmentCapacityNoticeMessage({
      threshold_bytes: 200000000,
      last_notified_at: noticeDate,
    }),
    /máximo.*200 MB.*purga/iu,
  );
});

test("accepts only the two capacity thresholds for per-user read state", async () => {
  const request = (value) =>
    new Request("https://openkanban.invalid/notices", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(value),
    });
  assert.equal(
    await readCapacityNoticeReadRequest(
      request({ threshold_bytes: 160000000 }),
    ),
    160000000,
  );
  assert.equal(
    await readCapacityNoticeReadRequest(
      request({ threshold_bytes: 200000000 }),
    ),
    200000000,
  );
  assert.equal(
    await readCapacityNoticeReadRequest(
      request({ threshold_bytes: 160000000, user_id: "someone-else" }),
    ),
    null,
  );
  assert.equal(
    await readCapacityNoticeReadRequest(
      request({ threshold_bytes: 180000000 }),
    ),
    null,
  );
  assert.equal(
    await readCapacityNoticeReadRequest(
      new Request("https://openkanban.invalid/notices", {
        method: "POST",
        body: JSON.stringify({ threshold_bytes: 160000000 }),
      }),
    ),
    null,
  );
});
