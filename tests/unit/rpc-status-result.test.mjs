import assert from "node:assert/strict";
import { test } from "node:test";
import { isRpcStatusResult } from "../../src/lib/rpc-status-result.ts";

test("RPC status result validation accepts only objects with string status", () => {
  assert.equal(isRpcStatusResult({ status: "confirmed" }), true);
  assert.equal(isRpcStatusResult(null), false);
  assert.equal(isRpcStatusResult({}), false);
  assert.equal(isRpcStatusResult({ status: 1 }), false);
});
