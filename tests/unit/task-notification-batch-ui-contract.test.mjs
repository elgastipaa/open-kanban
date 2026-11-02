import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const inbox = readFileSync(
  new URL(
    "../../src/components/notifications/task-notifications-inbox.tsx",
    import.meta.url,
  ),
  "utf8",
);
const batchState = readFileSync(
  new URL("../../src/lib/task-notification-batch-state.ts", import.meta.url),
  "utf8",
);

test("inbox starts one click-time batch and labels it with visible unread count", () => {
  assert.match(inbox, /const batchLock = useRef\(false\)/);
  assert.match(inbox, /acquireTaskNotificationBatchLock\(batchLock\)/);
  assert.match(inbox, /snapshotLoadedUnreadTaskNotificationIds\(items\)/);
  assert.match(inbox, /operationId: crypto\.randomUUID\(\)/);
  assert.match(inbox, /Marcar \{loadedUnreadCount\} visibles como leídas/);
  assert.match(inbox, /batchUncertain \|\|/);
  assert.doesNotMatch(inbox, /window\.(confirm|alert)\(/);
});

test("unavailable and uncertain outcomes hide content or reconcile before retry", () => {
  assert.match(
    inbox,
    /attempt\.status === "unavailable"[\s\S]+setItems\(hideTaskNotificationTargets\)[\s\S]+await refresh\(filter\)/,
  );
  assert.match(
    inbox,
    /hasUnavailableItem[\s\S]+await refresh\(filter\)[\s\S]+setBatchResult\(attempt\)/,
  );
  assert.match(
    batchState,
    /receipt = await api\.get\(operation\.operationId, operation\.notificationIds\)[\s\S]+if \(receipt\.status !== "not_found"\) return receipt;[\s\S]+api\.mark\(/,
  );
});

test("a definitive receipt miss refreshes authorized data before releasing the old batch", () => {
  assert.match(
    inbox,
    /attempt\.status === "not_found"[\s\S]+setItems\(hideTaskNotificationTargets\)[\s\S]+setRequiresBatchRefresh\(true\)[\s\S]+pendingNotFoundRefresh\.current = true;[\s\S]+await refresh\(filter\)[\s\S]+if \(!refreshed\) \{/,
  );
  assert.match(
    inbox,
    /const releaseMissingBatchAfterRefresh = useCallback\(\(\) => \{[\s\S]+if \(!pendingNotFoundRefresh\.current\) return;[\s\S]+pendingNotFoundRefresh\.current = false;[\s\S]+activeBatch\.current = null;[\s\S]+setBatchUncertain\(false\)/,
  );
  assert.equal(
    (inbox.match(/if \(!append\) releaseMissingBatchAfterRefresh\(\);/g) ?? [])
      .length,
    2,
    "only a successful full authorized refresh can release a definitive miss",
  );
  assert.match(
    inbox,
    /if \(nextFilter === filter \|\| isLoading \|\| isBatchBusy\) return/,
  );
  assert.equal(
    (inbox.match(/disabled=\{isLoading \|\| isBatchBusy\}/g) ?? []).length,
    3,
  );
  assert.match(
    inbox,
    /isBatchBusy \|\|\s+batchUncertain \|\|\s+requiresBatchRefresh \|\|\s+cursor === null/,
  );
});
