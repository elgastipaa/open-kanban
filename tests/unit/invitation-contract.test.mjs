import assert from "node:assert/strict";
import { test } from "node:test";
import { getSafeNextPath } from "../../src/lib/auth.ts";
import { parseInvitationPreview } from "../../src/lib/invitation-contract.ts";

test("invitation preview returns only authorized board, inviter, and role", () => {
  const preview = parseInvitationPreview({
    status: "available",
    board_name: "Equipo",
    inviter: "owner@example.test",
    role: "collaborator",
  });

  assert.deepEqual(preview, {
    status: "available",
    board_name: "Equipo",
    inviter: "owner@example.test",
    role: "collaborator",
  });
  assert.deepEqual(Object.keys(preview).sort(), [
    "board_name",
    "inviter",
    "role",
    "status",
  ]);
});

test("unavailable, malformed, and overbroad previews do not expose metadata", () => {
  assert.deepEqual(parseInvitationPreview({ status: "unavailable" }), {
    status: "unavailable",
  });
  assert.deepEqual(
    parseInvitationPreview({
      status: "available",
      board_name: "Equipo",
      inviter: "owner@example.test",
      role: "collaborator",
      board_slug: "private-route",
      task_titles: ["Secreto"],
    }),
    { status: "unavailable" },
  );
  assert.deepEqual(
    parseInvitationPreview({ status: "used", board_name: "Equipo" }),
    { status: "unavailable" },
  );
});

test("login can retain an invitation route without accepting it", () => {
  const token = "a".repeat(64);
  assert.equal(getSafeNextPath(`/invite/${token}`), `/invite/${token}`);
  assert.equal(getSafeNextPath("//example.test/invite"), "/");
});
