import assert from "node:assert/strict";
import test from "node:test";
import {
  acquireTaskNotificationBatchLock,
  applyTaskNotificationBatchResults,
  checkTaskNotificationBatch,
  parseTaskNotificationBatchResult,
  releaseTaskNotificationBatchLock,
  runTaskNotificationBatch,
  snapshotLoadedUnreadTaskNotificationIds,
  summarizeTaskNotificationBatch,
} from "../../src/lib/task-notification-batch-state.ts";

const id = (value) =>
  `a3800000-0000-4000-8000-${String(value).padStart(12, "0")}`;
const operation = (operationId, notificationIds, retryFailed = false) => ({
  operationId,
  notificationIds,
  retryFailed,
});

test("a click freezes only the loaded unread IDs, not later arrivals", () => {
  const loaded = Array.from({ length: 80 }, (_, index) => ({
    id: id(index + 1),
    read_at: index < 20 ? null : "2026-11-02T12:00:00.000Z",
  }));
  const batch = snapshotLoadedUnreadTaskNotificationIds(loaded.slice(0, 30));
  loaded.unshift({ id: id(81), read_at: null });

  assert.deepEqual(
    batch,
    loaded.slice(1, 21).map((item) => item.id),
  );
  assert.equal(batch.length, 20);
  assert.equal(batch.includes(id(81)), false);
});

test("batch results are keyed to the original IDs and separate all four outcomes", () => {
  const operationId = id(90);
  const ids = [id(1), id(2), id(3), id(4)];
  const parsed = parseTaskNotificationBatchResult(
    {
      status: "confirmed",
      operation_id: operationId,
      items: ids.map((notificationId, index) => ({
        id: notificationId,
        result: ["marked", "already_read", "unavailable", "failed"][index],
      })),
    },
    operationId,
    ids,
  );

  assert.deepEqual(
    parsed?.items.map((item) => item.result),
    ["marked", "already_read", "unavailable", "failed"],
  );
  assert.equal(
    parseTaskNotificationBatchResult(
      {
        status: "confirmed",
        operation_id: operationId,
        items: [{ id: id(5), result: "marked" }],
      },
      operationId,
      ids,
    ),
    null,
  );
});

test("double activation acquires one synchronous batch lock", async () => {
  const lock = { current: false };
  let requests = 0;
  let finishFirst;
  const first = new Promise((resolve) => {
    finishFirst = resolve;
  });
  const click = async () => {
    if (!acquireTaskNotificationBatchLock(lock)) return false;
    requests += 1;
    await first;
    releaseTaskNotificationBatchLock(lock);
    return true;
  };

  const firstClick = click();
  const secondClick = click();
  assert.equal(requests, 1);
  assert.equal(await secondClick, false);
  finishFirst();
  assert.equal(await firstClick, true);
  assert.equal(lock.current, false);
});

test("a lost response is reconciled before resending the same frozen operation", async () => {
  const operationId = id(90);
  const ids = [id(1), id(2)];
  const calls = [];
  const api = {
    async mark(...args) {
      calls.push(["mark", ...args]);
      if (calls.length === 1) throw new Error("timeout");
      return {
        status: "confirmed",
        operation_id: operationId,
        items: ids.map((notificationId) => ({
          id: notificationId,
          result: "marked",
        })),
      };
    },
    async get(...args) {
      calls.push(["get", ...args]);
      return { status: "not_found", operation_id: operationId };
    },
  };

  const result = await runTaskNotificationBatch(
    operation(operationId, ids),
    api,
  );
  assert.equal(result.status, "confirmed");
  assert.deepEqual(calls, [
    ["mark", operationId, ids, false],
    ["get", operationId, ids],
    ["mark", operationId, ids, false],
  ]);
});

test("a lost committed response uses its receipt without a second mutation", async () => {
  const operationId = id(90);
  const ids = [id(1), id(2)];
  let markCalls = 0;
  let getCalls = 0;
  const result = {
    status: "confirmed",
    operation_id: operationId,
    items: ids.map((notificationId) => ({
      id: notificationId,
      result: "marked",
    })),
  };
  const attempt = await runTaskNotificationBatch(operation(operationId, ids), {
    async mark() {
      markCalls += 1;
      throw new Error("response timed out after commit");
    },
    async get() {
      getCalls += 1;
      return result;
    },
  });

  assert.deepEqual(attempt, result);
  assert.equal(markCalls, 1);
  assert.equal(getCalls, 1);
});

test("an unverified receipt failure never causes a blind resend", async () => {
  const operationId = id(90);
  const ids = [id(1)];
  const calls = [];
  const result = await runTaskNotificationBatch(operation(operationId, ids), {
    async mark(...args) {
      calls.push(["mark", ...args]);
      throw new Error("timeout");
    },
    async get(...args) {
      calls.push(["get", ...args]);
      throw new Error("offline");
    },
  });

  assert.deepEqual(result, { status: "uncertain", operation_id: operationId });
  assert.deepEqual(calls, [
    ["mark", operationId, ids, false],
    ["get", operationId, ids],
  ]);
});

test("failed-only retries serialize absent-receipt reconciliation with the same batch", async () => {
  const operationId = id(90);
  const ids = [id(1), id(2)];
  const calls = [];
  const api = {
    async mark(...args) {
      calls.push(["mark", ...args]);
      if (calls.length === 1) throw new Error("response timed out");
      return { status: "not_found", operation_id: operationId };
    },
    async get(...args) {
      calls.push(["get", ...args]);
      return { status: "not_found", operation_id: operationId };
    },
  };

  const attempt = await runTaskNotificationBatch(
    operation(operationId, ids, true),
    api,
  );
  assert.deepEqual(attempt, { status: "not_found", operation_id: operationId });
  assert.deepEqual(calls, [
    ["mark", operationId, ids, true],
    ["get", operationId, ids],
    ["mark", operationId, ids, true],
  ]);

  calls.length = 0;
  const checked = await checkTaskNotificationBatch(
    operation(operationId, ids, true),
    api,
  );
  assert.deepEqual(checked, { status: "not_found", operation_id: operationId });
  assert.deepEqual(calls, [
    ["get", operationId, ids],
    ["mark", operationId, ids, true],
  ]);
});

test("a retry GET miss recovers a receipt confirmed by the serialized mark", async () => {
  const operationId = id(90);
  const ids = [id(1), id(2)];
  const calls = [];
  const result = {
    status: "confirmed",
    operation_id: operationId,
    items: ids.map((notificationId) => ({
      id: notificationId,
      result: "marked",
    })),
  };
  const checked = await checkTaskNotificationBatch(
    operation(operationId, ids, true),
    {
      async get(...args) {
        calls.push(["get", ...args]);
        return { status: "not_found", operation_id: operationId };
      },
      async mark(...args) {
        calls.push(["mark", ...args]);
        return result;
      },
    },
  );

  assert.deepEqual(checked, result);
  assert.deepEqual(calls, [
    ["get", operationId, ids],
    ["mark", operationId, ids, true],
  ]);
});

test("expired receipts stop after a timeout without replaying the mutation", async () => {
  const operationId = id(90);
  const ids = [id(1)];
  let marks = 0;
  let checks = 0;
  const result = await runTaskNotificationBatch(operation(operationId, ids), {
    async mark() {
      marks += 1;
      throw new Error("should not mark");
    },
    async get() {
      checks += 1;
      return { status: "expired_unknown", operation_id: operationId };
    },
  });

  assert.equal(result.status, "expired_unknown");
  assert.equal(marks, 1);
  assert.equal(checks, 1);
});

test("batch reconciliation updates visible rows and hides unavailable titles", () => {
  const result = {
    status: "confirmed",
    operation_id: id(90),
    items: [
      { id: id(1), result: "marked" },
      { id: id(2), result: "already_read" },
      { id: id(3), result: "unavailable" },
      { id: id(4), result: "failed" },
    ],
  };
  const items = result.items.map((item) => ({
    id: item.id,
    occurred_at: "2026-11-02T12:00:00.000Z",
    actor_name: "Persona autora",
    reason_codes: ["assignment"],
    task_title: "Privada",
    unavailable: false,
    read_at: null,
  }));
  const summary = summarizeTaskNotificationBatch(result);

  assert.deepEqual(summary, {
    marked: 1,
    already_read: 1,
    unavailable: 1,
    failed: 1,
  });
  const reconciled = applyTaskNotificationBatchResults(
    items,
    result.items,
    "2026-11-02T12:30:00.000Z",
    "all",
  );
  assert.equal(reconciled[0].read_at, "2026-11-02T12:30:00.000Z");
  assert.equal(reconciled[1].read_at, "2026-11-02T12:30:00.000Z");
  assert.equal(reconciled[2].task_title, null);
  assert.equal(reconciled[2].unavailable, true);
  assert.equal(reconciled[3].read_at, null);
  assert.equal(
    applyTaskNotificationBatchResults(items, result.items, "read", "unread")
      .map((item) => item.id)
      .join(","),
    id(4),
  );
});
