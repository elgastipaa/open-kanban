import assert from "node:assert/strict";
import test from "node:test";
import {
  applyTaskNotificationRead,
  buildTaskNotificationTargetHref,
  hideTaskNotificationTargets,
  openTaskNotificationTarget,
  parseTaskNotificationPage,
  parseTaskNotificationTarget,
  taskNotificationReasonLabel,
} from "../../src/lib/task-notification-state.ts";
import { buildUnifiedSearchHref } from "../../src/lib/unified-search-navigation.ts";

const notificationId = "a3700000-0000-4000-8000-000000000001";
const taskId = "a3700000-0000-4000-8000-000000000002";
const commentId = "a3700000-0000-4000-8000-000000000003";

const notificationItem = {
  id: notificationId,
  occurred_at: "2026-11-02T12:00:00.000Z",
  actor_name: "Persona autora",
  reason_codes: ["comment"],
  task_title: "Tarea asignada",
  unavailable: false,
  read_at: null,
};

test("marking read removes an item from the unread filter only", () => {
  const readAt = "2026-11-02T12:30:00.000Z";
  assert.deepEqual(
    applyTaskNotificationRead(
      [notificationItem],
      notificationId,
      readAt,
      "unread",
    ),
    [],
  );
  assert.deepEqual(
    applyTaskNotificationRead(
      [notificationItem],
      notificationId,
      readAt,
      "all",
    ),
    [{ ...notificationItem, read_at: readAt }],
  );
});

test("revalidation hides all cached task titles until authorized list refresh", () => {
  const second = { ...notificationItem, id: taskId, task_title: "Otra tarea" };
  assert.deepEqual(hideTaskNotificationTargets([notificationItem, second]), [
    { ...notificationItem, task_title: null, unavailable: true },
    { ...second, task_title: null, unavailable: true },
  ]);
});

test("notification page validates private display DTO and 90-day contract", () => {
  const page = parseTaskNotificationPage({
    status: "available",
    items: [
      {
        id: notificationId,
        occurred_at: "2026-11-02T12:00:00.000Z",
        actor_name: "Persona autora",
        reason_codes: ["comment", "mention"],
        task_title: "Tarea asignada",
        unavailable: false,
        read_at: null,
      },
    ],
    unread_count: 1,
    has_more: false,
    next_cursor: null,
    retention_days: 90,
  });

  assert.equal(page?.status, "available");
  if (page?.status === "available") {
    assert.equal(page.items.length, 1);
    assert.deepEqual(page.items[0].reason_codes, ["comment", "mention"]);
    assert.equal(page.unread_count, 1);
  }
  assert.equal(
    parseTaskNotificationPage({
      status: "available",
      items: [],
      unread_count: -1,
    }),
    null,
  );
  assert.equal(
    parseTaskNotificationPage({
      status: "available",
      items: [
        {
          id: notificationId,
          occurred_at: "2026-11-02T12:00:00.000Z",
          actor_name: "Persona autora",
          reason_codes: ["comment"],
          task_title: "No debe verse",
          unavailable: true,
          read_at: null,
        },
      ],
      unread_count: 0,
      has_more: false,
      next_cursor: null,
      retention_days: 90,
    }),
    null,
  );
});

test("unavailable destination is generic and cannot expose task IDs", () => {
  assert.deepEqual(parseTaskNotificationTarget({ status: "unavailable" }), {
    status: "unavailable",
  });
  assert.equal(
    parseTaskNotificationTarget({
      status: "available",
      slug: "private-board",
      task_id: taskId,
      comment_id: null,
      title: "private title",
    })?.status,
    "available",
  );
});

test("comment destination carries only stable IDs and anchors the exact comment", () => {
  const target = {
    status: "available",
    slug: "private-board",
    task_id: taskId,
    comment_id: commentId,
  };
  assert.equal(
    buildTaskNotificationTargetHref(target),
    `/private-board?task=${taskId}&comment=${commentId}#comment-${commentId}`,
  );
  assert.equal(
    buildTaskNotificationTargetHref({ ...target, slug: "//outside.invalid" }),
    null,
  );
});

test("opening resolves access before marking read and navigation", async () => {
  const calls = [];
  const result = await openTaskNotificationTarget(
    notificationId,
    async (id) => {
      calls.push(`resolve:${id}`);
      return {
        status: "available",
        slug: "private-board",
        task_id: taskId,
        comment_id: commentId,
      };
    },
    async (id) => {
      calls.push(`mark:${id}`);
      return "confirmed";
    },
    (href) => calls.push(`navigate:${href}`),
  );

  assert.equal(result, "opened");
  assert.deepEqual(calls, [
    `resolve:${notificationId}`,
    `mark:${notificationId}`,
    `navigate:/private-board?task=${taskId}&comment=${commentId}#comment-${commentId}`,
  ]);
});

test("inaccessible or changed destination is not marked or opened", async () => {
  let markCalls = 0;
  let navigations = 0;
  const result = await openTaskNotificationTarget(
    notificationId,
    async () => ({ status: "unavailable" }),
    async () => {
      markCalls += 1;
      return "confirmed";
    },
    () => {
      navigations += 1;
    },
  );

  assert.equal(result, "unavailable");
  assert.equal(markCalls, 0);
  assert.equal(navigations, 0);
});

test("notification reasons have Spanish, specific labels", () => {
  assert.equal(
    taskNotificationReasonLabel(["comment", "mention"]),
    "Te mencionaron en un comentario",
  );
  assert.equal(
    taskNotificationReasonLabel(["due_date"]),
    "Cambió el vencimiento de una tarea asignada",
  );
});

test("notifications route is not interpreted as a board slug", () => {
  assert.equal(
    buildUnifiedSearchHref("/notifications", new URLSearchParams()),
    "/search?scope=all",
  );
});
