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

test("PWA files remain public resources instead of being parsed as board slugs", () => {
  for (const pathname of [
    "/sw.js",
    "/manifest.webmanifest",
    "/offline.v1.html",
    "/icons/open-kanban-192.v1.svg",
    "/apple-icon",
  ]) {
    assert.equal(boardSlugFromProxyPath(pathname), null, pathname);
  }
});

test("account, API, and callback paths keep their existing request gates", () => {
  for (const pathname of ["/account", "/api/search", "/auth/callback"]) {
    assert.equal(boardSlugFromProxyPath(pathname), null, pathname);
  }
  assert.equal(boardSlugFromProxyPath("/planning-board"), "planning-board");
});

test("a private return destination remains intact through the login callback", () => {
  const next = "/planning-board?filter=assigned&task=synthetic-task";
  assert.equal(getSafeNextPath(next), next);
});
