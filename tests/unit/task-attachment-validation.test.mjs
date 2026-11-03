import assert from "node:assert/strict";
import { test } from "node:test";
import { validateTaskAttachmentPayload } from "../../src/lib/task-attachment-validation.ts";

const payload = (value) => new TextEncoder().encode(value);

test("accepts inert UTF-8 .txt/.md content through the inclusive 24,000-byte limit", () => {
  const exact = new Uint8Array(24_000).fill(0x61);
  const result = validateTaskAttachmentPayload("notas.md", exact);

  assert.equal(result.ok, true);
  assert.equal(result.sizeBytes, 24_000);
  assert.match(result.sha256, /^[0-9a-f]{64}$/);
});

test("rejects invalid extension, unsafe filename, and content above 24,000 bytes", () => {
  assert.equal(
    validateTaskAttachmentPayload("notas.pdf", payload("texto")).reason,
    "extension",
  );
  assert.equal(
    validateTaskAttachmentPayload("../notas.txt", payload("texto")).reason,
    "name",
  );
  assert.equal(
    validateTaskAttachmentPayload("notas\\texto.txt", payload("texto")).reason,
    "name",
  );
  assert.equal(
    validateTaskAttachmentPayload("notas.txt", new Uint8Array(24_001)).reason,
    "size",
  );
});

test("rejects empty, malformed, binary, and control-bearing content without replacement decoding", () => {
  assert.equal(
    validateTaskAttachmentPayload("notas.txt", new Uint8Array()).reason,
    "empty",
  );
  assert.equal(
    validateTaskAttachmentPayload("notas.txt", new Uint8Array([0xff, 0xfe]))
      .reason,
    "encoding",
  );
  assert.equal(
    validateTaskAttachmentPayload("notas.md", payload("%PDF-1.7\n")).reason,
    "binary",
  );
  assert.equal(
    validateTaskAttachmentPayload("notas.txt", payload("hola\u0000mundo"))
      .reason,
    "binary",
  );
});

test("does not accept control characters in filenames", () => {
  assert.equal(
    validateTaskAttachmentPayload("nota\n.txt", payload("texto")).reason,
    "name",
  );
});
