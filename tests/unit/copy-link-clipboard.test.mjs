import assert from "node:assert/strict";
import { test } from "node:test";
import { copyLinkToClipboard } from "../../src/lib/copy-link-clipboard.ts";

test("clipboard success waits for writeText to resolve", async () => {
  let resolveWrite;
  const writing = new Promise((resolve) => {
    resolveWrite = resolve;
  });
  const result = copyLinkToClipboard("/series?board=id", () => writing);
  let settled = false;
  void result.then(() => {
    settled = true;
  });

  await Promise.resolve();
  assert.equal(settled, false);

  resolveWrite();
  assert.equal(await result, true);
  assert.equal(settled, true);
});

test("clipboard rejection reports failure for a visible manual fallback", async () => {
  const result = await copyLinkToClipboard("/series?board=id", async () => {
    throw new Error("permission denied");
  });
  assert.equal(result, false);
});
