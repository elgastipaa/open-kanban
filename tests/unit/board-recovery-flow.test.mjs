import assert from "node:assert/strict";
import test from "node:test";
import {
  accessSuspensionResultEffect,
  parseAccessSuspensionPreview,
  prepareAccessSuspensionResolutions,
} from "../../src/lib/access-suspension-flow.ts";
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

const activeOwner = {
  board_id: "board-active-owner",
  state: "active",
  relationship: "owner",
  candidates: [
    { user_id: "successor-a", email: "a@example.test", is_admin: false },
  ],
};

const recoverableOwner = {
  board_id: "board-recoverable-owner",
  state: "recoverable",
  relationship: "owner",
  candidates: [
    { user_id: "successor-b", email: "b@example.test", is_admin: true },
  ],
  deleted_at: "2026-11-01T12:00:00Z",
  expires_at: "2026-11-08T12:00:00Z",
};

test("active ownership requires an explicit eligible successor", () => {
  assert.deepEqual(prepareAccessSuspensionResolutions([activeOwner], {}), {
    kind: "successor_required",
    board_ids: ["board-active-owner"],
  });
});

test("an active board with no eligible collaborator becomes recoverable", () => {
  assert.deepEqual(
    prepareAccessSuspensionResolutions(
      [{ ...activeOwner, candidates: [] }],
      {},
    ),
    {
      kind: "ready",
      resolutions: [
        {
          board_id: "board-active-owner",
          action: "recover",
          successor_id: null,
        },
      ],
    },
  );
});

test("a selected active-board successor must come from its eligible members", () => {
  assert.deepEqual(
    prepareAccessSuspensionResolutions([activeOwner], {
      "board-active-owner": "successor-a",
    }),
    {
      kind: "ready",
      resolutions: [
        {
          board_id: "board-active-owner",
          action: "transfer",
          successor_id: "successor-a",
        },
      ],
    },
  );
  assert.deepEqual(
    prepareAccessSuspensionResolutions([activeOwner], {
      "board-active-owner": "not-a-member",
    }),
    { kind: "successor_invalid", board_ids: ["board-active-owner"] },
  );
});

test("recoverable ownership changes recovery authority without restoring the board", () => {
  assert.deepEqual(
    prepareAccessSuspensionResolutions([recoverableOwner], {
      "board-recoverable-owner": "successor-b",
    }),
    {
      kind: "ready",
      resolutions: [
        {
          board_id: "board-recoverable-owner",
          action: "set_recovery_owner",
          successor_id: "successor-b",
        },
      ],
    },
  );
});

test("collaboration-only boards require no owner choice and keep their deletion deadline", () => {
  assert.deepEqual(
    prepareAccessSuspensionResolutions(
      [
        {
          ...recoverableOwner,
          board_id: "board-recoverable-collaborator",
          relationship: "collaborator",
          candidates: [],
        },
      ],
      {},
    ),
    { kind: "ready", resolutions: [] },
  );
});

test("without another enabled identity, an existing recovery remains unchanged", () => {
  assert.deepEqual(
    prepareAccessSuspensionResolutions(
      [{ ...recoverableOwner, candidates: [] }],
      {},
    ),
    {
      kind: "ready",
      resolutions: [
        {
          board_id: "board-recoverable-owner",
          action: "leave_recovery_unassigned",
          successor_id: null,
        },
      ],
    },
  );
});

test("an already active recovery owner needs no new succession choice", () => {
  assert.deepEqual(
    prepareAccessSuspensionResolutions(
      [
        {
          ...recoverableOwner,
          relationship: "owner",
          recovery_owner_id: "another-owner",
          recovery_owner_is_active: true,
          candidates: [],
        },
      ],
      {},
    ),
    { kind: "ready", resolutions: [] },
  );
});

test("suspension preview accepts metadata-only board summaries", () => {
  assert.deepEqual(
    parseAccessSuspensionPreview({
      status: "ready",
      boards: [
        {
          board_id: "board-active-owner",
          slug: "private-slug",
          name: "Private board name",
          state: "active",
          relationship: "owner",
          active_member_count: 2,
          deleted_at: null,
          expires_at: null,
          recovery_owner_id: null,
          recovery_owner_is_active: false,
          candidates: [
            {
              user_id: "successor-a",
              email: "a@example.test",
              is_admin: false,
            },
          ],
        },
      ],
    }),
    {
      status: "ready",
      boards: [
        {
          board_id: "board-active-owner",
          slug: "private-slug",
          name: "Private board name",
          state: "active",
          relationship: "owner",
          active_member_count: 2,
          deleted_at: null,
          expires_at: null,
          recovery_owner_id: null,
          recovery_owner_is_active: false,
          candidates: [
            {
              user_id: "successor-a",
              email: "a@example.test",
              is_admin: false,
            },
          ],
        },
      ],
    },
  );
});

test("suspension preview fails closed if a board content field is returned", () => {
  assert.equal(
    parseAccessSuspensionPreview({
      status: "ready",
      boards: [
        {
          board_id: "board-active-owner",
          slug: "private-slug",
          name: "Private board name",
          state: "active",
          relationship: "owner",
          active_member_count: 2,
          deleted_at: null,
          expires_at: null,
          recovery_owner_id: null,
          recovery_owner_is_active: false,
          candidates: [],
          tasks: [{ title: "secret" }],
        },
      ],
    }),
    null,
  );
});

test("an unavailable suspension result clears stale choices and refreshes access", () => {
  assert.deepEqual(accessSuspensionResultEffect("unavailable"), {
    kind: "stale_account",
    clearPreview: true,
    refreshAccess: true,
  });
});

test("mixed board choices are stable and never include membership-only boards", () => {
  const result = prepareAccessSuspensionResolutions(
    [
      {
        ...recoverableOwner,
        board_id: "board-collaborator",
        relationship: "collaborator",
        candidates: [],
      },
      activeOwner,
      { ...recoverableOwner, candidates: [] },
    ],
    { "board-active-owner": "successor-a" },
  );
  assert.deepEqual(result, {
    kind: "ready",
    resolutions: [
      {
        board_id: "board-active-owner",
        action: "transfer",
        successor_id: "successor-a",
      },
      {
        board_id: "board-recoverable-owner",
        action: "leave_recovery_unassigned",
        successor_id: null,
      },
    ],
  });
});
