import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const modalSource = await readFile(
  new URL("../../src/components/ui/modal.tsx", import.meta.url),
  "utf8",
);
const taskModalSource = await readFile(
  new URL("../../src/components/board/task-modal.tsx", import.meta.url),
  "utf8",
);

test("a modal returns focus to the element that opened it", () => {
  assert.doesNotMatch(modalSource, /returnFocusTo/);
  assert.doesNotMatch(taskModalSource, /lastEditorInputRef|returnFocusTo/);
  assert.match(modalSource, /returnFocusRef\.current\s*=\s*activeElement/);
  assert.match(
    modalSource,
    /if \(returnFocusRef\.current\?\.isConnected\) \{\s*returnFocusRef\.current\.focus\(\{\s*preventScroll:\s*true\s*\}\)/,
  );
});
