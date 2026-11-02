import assert from "node:assert/strict";
import { test } from "node:test";
import {
  cancelBoardMemberRemoval,
  confirmBoardMemberRemoval,
  createBoardMemberRemovalCommand,
  createBoardMemberRemovalFlow,
  createBoardMemberRemovalSubmissionGate,
  finishBoardMemberRemoval,
  getExpiredUnknownBoardMemberRemoval,
  rememberExpiredUnknownBoardMemberRemoval,
  requestBoardMemberRemoval,
  retryBoardMemberRemoval,
  startBoardMemberRemoval,
} from "../../src/lib/board-member-removal-flow.ts";

const collaborator = {
  membership_id: "a7180000-0000-4000-8000-000000000011",
  user_id: "41600000-0000-4000-8000-000000000002",
  name: "Colaborador",
  role: "collaborator",
};

test("canceling collaborator removal returns to the roster without an RPC", async () => {
  let submitCalls = 0;
  const roster = createBoardMemberRemovalFlow();
  const confirmation = requestBoardMemberRemoval(roster, "owner", collaborator);
  const canceled = cancelBoardMemberRemoval(confirmation);
  const result = await confirmBoardMemberRemoval(
    canceled,
    "41600000-0000-4000-8000-000000000010",
    "a7180000-0000-4000-8000-000000000012",
    async () => {
      submitCalls += 1;
      return { status: "confirmed" };
    },
  );

  assert.equal(confirmation.status, "confirming");
  assert.equal(canceled.status, "roster");
  assert.equal(
    createBoardMemberRemovalCommand(
      canceled,
      "41600000-0000-4000-8000-000000000010",
      "a7180000-0000-4000-8000-000000000012",
    ),
    null,
  );
  assert.deepEqual(result, { status: "not_ready" });
  assert.equal(submitCalls, 0);
});

test("only an owner can open confirmation for a collaborator, never for an owner", () => {
  const roster = createBoardMemberRemovalFlow();
  const ownerRequest = requestBoardMemberRemoval(roster, "owner", collaborator);
  const collaboratorRequest = requestBoardMemberRemoval(
    roster,
    "collaborator",
    collaborator,
  );
  const ownerTargetRequest = requestBoardMemberRemoval(roster, "owner", {
    ...collaborator,
    role: "owner",
  });

  assert.equal(ownerRequest.status, "confirming");
  assert.equal(collaboratorRequest, roster);
  assert.equal(ownerTargetRequest, roster);
});

test("confirmation targets one membership episode and retry preserves the same operation", async () => {
  const confirmation = requestBoardMemberRemoval(
    createBoardMemberRemovalFlow(),
    "owner",
    collaborator,
  );
  let submitted;
  const result = await confirmBoardMemberRemoval(
    confirmation,
    "41600000-0000-4000-8000-000000000010",
    "a7180000-0000-4000-8000-000000000013",
    async (command) => {
      submitted = command;
      return { status: "retryable" };
    },
  );

  assert.deepEqual(submitted, {
    operation_id: "a7180000-0000-4000-8000-000000000013",
    board_id: "41600000-0000-4000-8000-000000000010",
    membership_id: collaborator.membership_id,
  });
  const command = createBoardMemberRemovalCommand(
    confirmation,
    "41600000-0000-4000-8000-000000000010",
    "a7180000-0000-4000-8000-000000000013",
  );
  const submitting = startBoardMemberRemoval(confirmation, command);
  const uncertain = finishBoardMemberRemoval(submitting, result.status);
  const retry = retryBoardMemberRemoval(uncertain);

  assert.equal(retry.status, "submitting");
  assert.deepEqual(retry.command, command);
});

test("a stale membership conflict refreshes the roster and does not report success", () => {
  const confirmation = requestBoardMemberRemoval(
    createBoardMemberRemovalFlow(),
    "owner",
    collaborator,
  );
  const command = createBoardMemberRemovalCommand(
    confirmation,
    "41600000-0000-4000-8000-000000000010",
    "a7180000-0000-4000-8000-000000000014",
  );
  const submitting = startBoardMemberRemoval(confirmation, command);
  const result = finishBoardMemberRemoval(submitting, "conflict");

  assert.equal(result.status, "roster");
  assert.match(result.error, /membresía cambió/);
  assert.equal(result.message, undefined);
});

test("duplicate removal confirmation is gated while the first submit is pending", async () => {
  const gate = createBoardMemberRemovalSubmissionGate();
  let finishFirst;
  let calls = 0;
  const first = gate(
    () =>
      new Promise((resolve) => {
        calls += 1;
        finishFirst = resolve;
      }),
  );
  const second = await gate(async () => {
    calls += 1;
    return { status: "confirmed" };
  });
  finishFirst({ status: "confirmed" });
  const firstResult = await first;

  assert.deepEqual(second, { status: "already_submitting" });
  assert.deepEqual(firstResult, { status: "confirmed" });
  assert.equal(calls, 1);
});

test("expired unknown blocks a new operation for the same membership episode only", () => {
  const command = {
    operation_id: "a7180000-0000-4000-8000-000000000015",
    board_id: "41600000-0000-4000-8000-000000000010",
    membership_id: collaborator.membership_id,
  };
  rememberExpiredUnknownBoardMemberRemoval(
    "41600000-0000-4000-8000-000000000001",
    command,
  );

  assert.deepEqual(
    getExpiredUnknownBoardMemberRemoval(
      "41600000-0000-4000-8000-000000000001",
      command.board_id,
      command.membership_id,
    ),
    command,
  );
  assert.equal(
    getExpiredUnknownBoardMemberRemoval(
      "41600000-0000-4000-8000-000000000001",
      command.board_id,
      "a7180000-0000-4000-8000-000000000016",
    ),
    null,
  );
  assert.equal(
    getExpiredUnknownBoardMemberRemoval(
      "41600000-0000-4000-8000-000000000099",
      command.board_id,
      command.membership_id,
    ),
    null,
  );
});
