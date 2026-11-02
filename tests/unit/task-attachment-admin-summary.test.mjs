import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { parseAdminTaskAttachmentStorageSummary } from "../../src/lib/admin-task-attachment-storage-summary.ts";

const source = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const adminStorage = source(
  "../../src/components/admin/task-attachment-storage.tsx",
);
const ownerStorage = source(
  "../../src/components/board/task-attachment-storage.tsx",
);
const summary = {
  status: "ok",
  limit_bytes: 200000000,
  used_bytes: 321,
  active_bytes: 100,
  recoverable_bytes: 80,
  reserved_bytes: 60,
  pending_bytes: 81,
  active_count: 4,
  recoverable_count: 3,
  reserved_count: 2,
  pending_count: 1,
};

test("admin summary preserves each global storage category independently", () => {
  assert.deepEqual(parseAdminTaskAttachmentStorageSummary(summary), {
    limit_bytes: 200000000,
    used_bytes: 321,
    active_bytes: 100,
    recoverable_bytes: 80,
    reserved_bytes: 60,
    pending_bytes: 81,
    active_count: 4,
    recoverable_count: 3,
    reserved_count: 2,
    pending_count: 1,
  });
});

test("admin summary rejects unavailable, incomplete, or unsafe counts", () => {
  assert.equal(
    parseAdminTaskAttachmentStorageSummary({
      ...summary,
      status: "unavailable",
    }),
    null,
  );
  assert.equal(
    parseAdminTaskAttachmentStorageSummary({
      ...summary,
      reserved_bytes: undefined,
    }),
    null,
  );
  assert.equal(
    parseAdminTaskAttachmentStorageSummary({ ...summary, pending_count: -1 }),
    null,
  );
  assert.equal(
    parseAdminTaskAttachmentStorageSummary({ ...summary, active_bytes: "100" }),
    null,
  );
});

test("admin capacity displays reservations separately from pending cleanup", () => {
  assert.match(adminStorage, /<dt[^>]*>Activos<\/dt>/);
  assert.match(adminStorage, /summary\.active_bytes/);
  assert.match(adminStorage, /<dt[^>]*>En recuperación<\/dt>/);
  assert.match(adminStorage, /summary\.recoverable_bytes/);
  assert.match(adminStorage, /<dt[^>]*>Reservas<\/dt>/);
  assert.match(adminStorage, /summary\.reserved_bytes/);
  assert.match(adminStorage, /<dt[^>]*>Limpieza pendiente<\/dt>/);
  assert.match(adminStorage, /summary\.pending_bytes/);
  assert.doesNotMatch(
    adminStorage,
    /summary\.reserved_bytes\s*\+\s*summary\.pending_bytes/,
  );
});

test("board owners see only their own breakdown beside the global total", () => {
  assert.match(ownerStorage, /page\.board_usage\.active_bytes/);
  assert.match(ownerStorage, /page\.board_usage\.recoverable_bytes/);
  assert.match(ownerStorage, /page\.board_usage\.reserved_bytes/);
  assert.match(ownerStorage, /page\.board_usage\.pending_bytes/);
  assert.match(ownerStorage, /page\.global_capacity\.used_bytes/);
  assert.doesNotMatch(
    ownerStorage,
    /global_capacity\.(active_bytes|recoverable_bytes|reserved_bytes|pending_bytes)/,
  );
});
