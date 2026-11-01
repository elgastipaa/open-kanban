import assert from "node:assert/strict";
import test from "node:test";
import {
  adminMayResolveBoardRecovery,
  formatBoardRecoveryDates,
  prepareBoardRestoreCommand,
} from "../../src/lib/board-recovery-flow.ts";

test("recovery metadata shows both deletion time and exact expiry", () => {
  assert.equal(
    formatBoardRecoveryDates(
      "deleted-at",
      "expires-at",
      (value) => `formatted ${value}`,
    ),
    "Borrado el formatted deleted-at · Recuperable hasta formatted expires-at",
  );
});

test("an administrator cannot restore while the current enabled owner is valid", () => {
  assert.equal(adminMayResolveBoardRecovery(true), false);
  assert.equal(adminMayResolveBoardRecovery(false), true);
});

test("owner selection creates one stable restore command", () => {
  const decision = prepareBoardRestoreCommand("new-owner", null, () => "op-1");
  assert.deepEqual(decision, {
    kind: "ready",
    isRetry: false,
    command: { operationId: "op-1", ownerId: "new-owner" },
  });
});

test("an uncertain retry keeps its operation id and chosen owner", () => {
  const existing = { operationId: "op-1", ownerId: "new-owner" };
  const decision = prepareBoardRestoreCommand(
    "new-owner",
    existing,
    () => "op-2",
  );
  assert.deepEqual(decision, {
    kind: "ready",
    isRetry: true,
    command: existing,
  });
});

test("a pending uncertain command cannot silently switch owner", () => {
  const existing = { operationId: "op-1", ownerId: "new-owner" };
  assert.deepEqual(
    prepareBoardRestoreCommand("another-owner", existing, () => "op-2"),
    { kind: "owner_locked", command: existing },
  );
});

test("restore waits for an explicit owner choice", () => {
  assert.deepEqual(
    prepareBoardRestoreCommand("", null, () => "op-1"),
    {
      kind: "owner_required",
    },
  );
});
