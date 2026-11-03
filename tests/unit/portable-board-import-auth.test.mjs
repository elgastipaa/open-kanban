import assert from "node:assert/strict";
import { test } from "node:test";
import { runAfterCurrentBoardOwnerCheck } from "../../src/lib/portable-board-import-auth.ts";

function ownerClient({ data, error = null }) {
  const filters = [];
  const query = {
    select(columns) {
      assert.equal(columns, "id");
      return query;
    },
    eq(column, value) {
      filters.push([column, value]);
      return query;
    },
    async maybeSingle() {
      return { data, error };
    },
  };
  return {
    filters,
    from(table) {
      assert.equal(table, "boards");
      return query;
    },
  };
}

test("a non-owner is rejected before the request body or ZIP spool is read", async () => {
  const client = ownerClient({ data: null });
  let requestBodyReads = 0;
  let spoolCreates = 0;

  const result = await runAfterCurrentBoardOwnerCheck(
    {
      client,
      actorId: "11111111-1111-4111-8111-111111111111",
      slug: "synthetic-board",
    },
    async () => {
      requestBodyReads += 1;
      spoolCreates += 1;
      return "spooled";
    },
  );

  assert.equal(result.status, "not_owner");
  assert.equal(requestBodyReads, 0);
  assert.equal(spoolCreates, 0);
  assert.deepEqual(client.filters, [
    ["slug", "synthetic-board"],
    ["owner_id", "11111111-1111-4111-8111-111111111111"],
  ]);
});

test("a current owner may read the request after the ownership check", async () => {
  const client = ownerClient({ data: { id: "synthetic-board-id" } });
  const result = await runAfterCurrentBoardOwnerCheck(
    {
      client,
      actorId: "22222222-2222-4222-8222-222222222222",
      slug: "synthetic-board",
    },
    async () => "spooled",
  );

  assert.deepEqual(result, { status: "authorized", value: "spooled" });
});
