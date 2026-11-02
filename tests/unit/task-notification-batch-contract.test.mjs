import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync(
  new URL("../../src/lib/db/task-notifications.ts", import.meta.url),
  "utf8",
);

test("batch RPC keeps the frozen IDs and retries through the same operation", () => {
  assert.match(source, /"mark_my_task_notifications_batch_p"/);
  assert.match(source, /p_operation_id:\s*operationId/);
  assert.match(source, /p_notification_ids:\s*notificationIds/);
  assert.match(source, /p_retry_failed:\s*retryFailed/);
  assert.match(source, /"get_my_task_notification_batch_p"/);
});

test("batch transport errors expose no SQL or notification content", () => {
  assert.match(source, /No se pudo confirmar el lote de novedades\./);
  assert.match(source, /if \(error\) throw new TaskNotificationBatchError\(\)/);
});
