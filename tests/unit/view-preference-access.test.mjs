import assert from "node:assert/strict";
import { test } from "node:test";
import {
  isViewPreferenceAccessDenied,
  ViewPreferenceError,
} from "../../src/lib/view-preference-error.ts";

test("only a typed access denial clears private view preferences", () => {
  assert.equal(
    isViewPreferenceAccessDenied(new ViewPreferenceError("access_denied")),
    true,
  );
  assert.equal(
    isViewPreferenceAccessDenied(new ViewPreferenceError("uncertain")),
    false,
  );
  assert.equal(
    isViewPreferenceAccessDenied(new ViewPreferenceError("invalid")),
    false,
  );
  assert.equal(
    isViewPreferenceAccessDenied(new Error("network timeout")),
    false,
  );
});
