import assert from "node:assert/strict";
import { test } from "node:test";
import {
  parseTaskNotificationPage,
  taskNotificationReasonLabel,
} from "../../src/lib/task-notification-state.ts";

test("admin cleanup notice is accepted and labeled without naming the file", () => {
  const page = parseTaskNotificationPage({
    status: "available",
    unread_count: 1,
    has_more: false,
    next_cursor: null,
    retention_days: 90,
    items: [
      {
        id: "81000000-0000-4000-8000-000000000001",
        occurred_at: "2026-11-01T12:00:00Z",
        actor_name: "Administración",
        reason_codes: ["attachment_cleanup"],
        task_title: "Revisión mensual",
        unavailable: false,
        read_at: null,
      },
    ],
  });

  assert.ok(page && page.status === "available");
  assert.equal(
    taskNotificationReasonLabel(page.items[0].reason_codes),
    "Se limpió un archivo de esta tarea",
  );
});
