import assert from "node:assert/strict";
import { test } from "node:test";
import {
  listTaskActivity,
  TaskActivityError,
} from "../../src/lib/db/task-activity.ts";

test("activity adapter sends a stable cursor and parses its retention window", async () => {
  const calls = [];
  const occurredAt = "2026-11-02T12:00:00.000Z";
  const supabase = {
    async rpc(name, args) {
      calls.push({ name, args });
      return {
        data: {
          status: "available",
          events: [
            {
              id: "event-2",
              category: "assignee",
              actor_type: "user",
              actor_name: "Ana",
              occurred_at: occurredAt,
              before_value: "Sin responsable",
              after_value: "Bruno",
            },
          ],
          has_more: true,
          next_cursor: { occurred_at: occurredAt, id: "event-2" },
          retention_days: 180,
        },
        error: null,
      };
    },
  };

  const page = await listTaskActivity(supabase, "board", "task", {
    limit: 1,
    cursor: { occurred_at: "2026-11-02T11:00:00.000Z", id: "event-1" },
  });
  assert.deepEqual(calls, [
    {
      name: "get_task_activity_p",
      args: {
        p_slug: "board",
        p_task_id: "task",
        p_limit: 1,
        p_before_occurred_at: "2026-11-02T11:00:00.000Z",
        p_before_id: "event-1",
      },
    },
  ]);
  assert.equal(page.status, "available");
  assert.equal(page.retention_days, 180);
  assert.deepEqual(page.events[0], {
    id: "event-2",
    category: "assignee",
    actor_type: "user",
    actor_name: "Ana",
    occurred_at: occurredAt,
    before_value: "Sin responsable",
    after_value: "Bruno",
  });
});

test("activity adapter distinguishes inaccessible data and rejects malformed pages", async () => {
  const unavailable = await listTaskActivity(
    {
      async rpc() {
        return { data: { status: "unavailable" }, error: null };
      },
    },
    "board",
    "task",
  );
  assert.deepEqual(unavailable, { status: "unavailable" });

  await assert.rejects(
    listTaskActivity(
      {
        async rpc() {
          return { data: { status: "available", events: [] }, error: null };
        },
      },
      "board",
      "task",
    ),
    TaskActivityError,
  );
});
