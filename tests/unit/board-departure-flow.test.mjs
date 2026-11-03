import assert from "node:assert/strict";
import { test } from "node:test";
import {
  cancelBoardDeparture,
  confirmBoardDeparture,
  createBoardDepartureCommand,
  createBoardDepartureFlow,
  createBoardDepartureSubmissionGate,
  getBoardDepartureResultEffect,
  getExpiredUnknownBoardDeparture,
  rememberExpiredUnknownBoardDeparture,
  selectBoardDepartureSuccessor,
} from "../../src/lib/board-departure-flow.ts";

const owner = {
  role: "owner",
  actorId: "41600000-0000-4000-8000-000000000001",
  hasOtherCurrentMembers: true,
  eligibleSuccessors: [
    {
      user_id: "41600000-0000-4000-8000-000000000002",
      name: "Ada",
      email: "ada@example.test",
      role: "collaborator",
    },
  ],
};

test("cancel closes a departure review without calling the RPC submitter", async () => {
  let submitCalls = 0;
  const review = createBoardDepartureFlow({
    role: "collaborator",
    actorId: owner.actorId,
    hasOtherCurrentMembers: true,
    eligibleSuccessors: [],
  });
  const closed = cancelBoardDeparture(review);

  const result = await confirmBoardDeparture(
    closed,
    "41600000-0000-4000-8000-000000000010",
    "4c000000-0000-4000-8000-000000000001",
    async () => {
      submitCalls += 1;
      return { status: "confirmed" };
    },
  );

  assert.equal(closed.status, "closed");
  assert.equal(result.status, "not_ready");
  assert.equal(submitCalls, 0);
});

test("a collaborator confirms exit without a successor", async () => {
  let submitted;
  const review = createBoardDepartureFlow({
    role: "collaborator",
    actorId: owner.actorId,
    hasOtherCurrentMembers: true,
    eligibleSuccessors: [],
  });
  const result = await confirmBoardDeparture(
    review,
    "41600000-0000-4000-8000-000000000010",
    "4c000000-0000-4000-8000-000000000005",
    async (command) => {
      submitted = command;
      return { status: "confirmed" };
    },
  );

  assert.equal(result.status, "confirmed");
  assert.deepEqual(submitted, {
    action: "leave",
    operation_id: "4c000000-0000-4000-8000-000000000005",
    board_id: "41600000-0000-4000-8000-000000000010",
    successor_user_id: null,
  });
});

test("an owner must explicitly choose one of the current eligible successors", async () => {
  let submitted;
  const review = createBoardDepartureFlow(owner);
  const result = await confirmBoardDeparture(
    review,
    "41600000-0000-4000-8000-000000000010",
    "4c000000-0000-4000-8000-000000000002",
    async (command) => {
      submitted = command;
      return { status: "confirmed" };
    },
  );
  assert.equal(result.status, "not_ready");
  assert.equal(submitted, undefined);

  const selected = selectBoardDepartureSuccessor(
    review,
    owner.eligibleSuccessors[0].user_id,
  );
  await confirmBoardDeparture(
    selected,
    "41600000-0000-4000-8000-000000000010",
    "4c000000-0000-4000-8000-000000000003",
    async (command) => {
      submitted = command;
      return { status: "confirmed" };
    },
  );
  assert.deepEqual(submitted, {
    action: "leave",
    operation_id: "4c000000-0000-4000-8000-000000000003",
    board_id: "41600000-0000-4000-8000-000000000010",
    successor_user_id: owner.eligibleSuccessors[0].user_id,
  });
});

test("recoverable deletion is offered only when the server confirms no other current member", async () => {
  let submitted;
  const lastMember = createBoardDepartureFlow({
    role: "owner",
    actorId: owner.actorId,
    hasOtherCurrentMembers: false,
    eligibleSuccessors: [],
  });
  await confirmBoardDeparture(
    lastMember,
    "41600000-0000-4000-8000-000000000010",
    "4c000000-0000-4000-8000-000000000004",
    async (command) => {
      submitted = command;
      return { status: "recoverable" };
    },
  );
  assert.deepEqual(submitted, {
    action: "delete_last_member",
    operation_id: "4c000000-0000-4000-8000-000000000004",
    board_id: "41600000-0000-4000-8000-000000000010",
  });

  const blocked = createBoardDepartureFlow({
    ...owner,
    hasOtherCurrentMembers: null,
    eligibleSuccessors: [],
  });
  assert.equal(blocked.status, "blocked");
  assert.equal(blocked.reason, "membership_status_unavailable");
});

test("a disabled active member prevents last-member deletion without becoming a successor", () => {
  const blocked = createBoardDepartureFlow({
    ...owner,
    hasOtherCurrentMembers: true,
    eligibleSuccessors: [],
  });
  assert.equal(blocked.status, "blocked");
  assert.equal(blocked.reason, "no_eligible_successor");
});

test("result effects refresh stale eligibility, retry the same command, and leave lost access", () => {
  assert.equal(getBoardDepartureResultEffect("conflict"), "refresh_review");
  assert.equal(
    getBoardDepartureResultEffect("retryable"),
    "retry_same_command",
  );
  assert.equal(
    getBoardDepartureResultEffect("expired_unknown"),
    "block_expired_intent",
  );
  assert.equal(getBoardDepartureResultEffect("access_denied"), "leave_context");
  assert.equal(getBoardDepartureResultEffect("unavailable"), "leave_context");
  assert.equal(getBoardDepartureResultEffect("confirmed"), "leave_context");
});

test("closing and reopening clears a selected but unsubmitted successor", () => {
  const review = createBoardDepartureFlow(owner);
  const selected = selectBoardDepartureSuccessor(
    review,
    owner.eligibleSuccessors[0].user_id,
  );
  const closed = cancelBoardDeparture(selected);
  const reopened = createBoardDepartureFlow(owner);

  assert.equal(closed.status, "closed");
  assert.equal(reopened.status, "review");
  assert.equal(reopened.successor_user_id, null);
});

test("a pending confirmation prevents a second RPC while loading", async () => {
  const gate = createBoardDepartureSubmissionGate();
  let submitCalls = 0;
  let release;
  const pending = gate(() => {
    submitCalls += 1;
    return new Promise((resolve) => {
      release = resolve;
    });
  });
  const duplicate = await gate(async () => {
    submitCalls += 1;
    return { status: "confirmed" };
  });

  assert.deepEqual(duplicate, { status: "already_submitting" });
  assert.equal(submitCalls, 1);
  release({ status: "confirmed" });
  assert.deepEqual(await pending, { status: "confirmed" });
});

test("uncertain confirmation retries preserve the same operation and payload", async () => {
  const review = selectBoardDepartureSuccessor(
    createBoardDepartureFlow(owner),
    owner.eligibleSuccessors[0].user_id,
  );
  const commands = [];
  await confirmBoardDeparture(
    review,
    "41600000-0000-4000-8000-000000000010",
    "4c000000-0000-4000-8000-000000000006",
    async (command) => {
      commands.push(command);
      return { status: "retryable" };
    },
  );
  await confirmBoardDeparture(
    review,
    "41600000-0000-4000-8000-000000000010",
    "4c000000-0000-4000-8000-000000000006",
    async (command) => {
      commands.push(command);
      return { status: "confirmed" };
    },
  );

  assert.equal(commands.length, 2);
  assert.deepEqual(commands[0], commands[1]);
});

test("expired unknown intent blocks every new key for the board in the current UI session", () => {
  const review = selectBoardDepartureSuccessor(
    createBoardDepartureFlow(owner),
    owner.eligibleSuccessors[0].user_id,
  );
  const command = createBoardDepartureCommand(
    review,
    "41600000-0000-4000-8000-000000000010",
    "4c000000-0000-4000-8000-000000000007",
  );
  rememberExpiredUnknownBoardDeparture(owner.actorId, command);

  assert.deepEqual(
    getExpiredUnknownBoardDeparture(owner.actorId, command),
    command,
  );
  const reviewWithAlternate = createBoardDepartureFlow({
    ...owner,
    eligibleSuccessors: [
      ...owner.eligibleSuccessors,
      {
        user_id: "41600000-0000-4000-8000-000000000003",
        name: "Grace",
        email: "grace@example.test",
        role: "collaborator",
      },
    ],
  });
  const otherSelection = createBoardDepartureCommand(
    selectBoardDepartureSuccessor(
      reviewWithAlternate,
      "41600000-0000-4000-8000-000000000003",
    ),
    "41600000-0000-4000-8000-000000000010",
    "4c000000-0000-4000-8000-000000000008",
  );
  assert.deepEqual(
    getExpiredUnknownBoardDeparture(owner.actorId, otherSelection),
    command,
    "changing a successor cannot replace an expired unknown operation",
  );
});
