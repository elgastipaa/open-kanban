import assert from "node:assert/strict";
import { test } from "node:test";
import { getSafeNextPath } from "../../src/lib/auth.ts";
import { boardSlugFromProxyPath } from "../../src/lib/proxy-path.ts";

test("the exact invite route and token bypass board-slug normalization", () => {
  const token = "a".repeat(64);
  const path = `/invite/${token}`;

  assert.equal(boardSlugFromProxyPath(path), null);
  assert.equal(getSafeNextPath(path), path);
  assert.equal(getSafeNextPath("//example.test/invite"), "/");
});

test("only the invite path segment is reserved", () => {
  assert.equal(boardSlugFromProxyPath("/invitation-board"), "invitation-board");
});
