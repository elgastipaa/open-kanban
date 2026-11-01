import assert from "node:assert/strict";
import test from "node:test";
import { ensureImportReplacementAvailable } from "../../src/lib/import-replacement-boundary.ts";

test("an import into a board with existing content is rejected before writes", () => {
  assert.throws(
    () => ensureImportReplacementAvailable(1),
    /No se realizó ningún cambio/,
  );
});

test("an empty board can still accept imported content", () => {
  assert.doesNotThrow(() => ensureImportReplacementAvailable(0));
});
