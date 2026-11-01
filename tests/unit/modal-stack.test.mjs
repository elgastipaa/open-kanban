import assert from "node:assert/strict";
import test from "node:test";

const { ModalStack } = await import("../../src/lib/modal-stack.ts");

test("only the topmost modal handles Escape and focus trapping", () => {
  const stack = new ModalStack();
  const editor = Symbol("editor");
  const account = Symbol("account");
  const closeEditor = stack.activate(editor);

  assert.equal(stack.isTop(editor), true);
  const closeAccount = stack.activate(account);
  assert.equal(stack.isTop(account), true);
  assert.equal(stack.isTop(editor), false);

  closeAccount();
  assert.equal(stack.isTop(editor), true);
  closeEditor();
  assert.equal(stack.isTop(editor), false);
});

test("overlapping modal cleanup restores document scrolling after the last close", () => {
  const stack = new ModalStack();
  const editor = Symbol("editor");
  const account = Symbol("account");
  const body = { style: { overflow: "scroll" } };
  const closeEditor = stack.activate(editor, body);
  const closeAccount = stack.activate(account, body);

  assert.equal(body.style.overflow, "hidden");
  closeEditor();
  assert.equal(body.style.overflow, "hidden");
  closeAccount();
  assert.equal(body.style.overflow, "scroll");
});
