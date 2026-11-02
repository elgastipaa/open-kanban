import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { postUnifiedSearch } from "../../src/lib/unified-search-state.ts";

test("retry and focus revalidation send a fresh POST and resolve its response", async () => {
  const payload = { query: "reunión", scope: "all" };
  const calls = [];
  const fetcher = async (input, init) => {
    calls.push({ input, init });
    return new Response(
      JSON.stringify({
        status: "available",
        results: [{ kind: "task", task_id: `task-${calls.length}` }],
      }),
      { status: 200 },
    );
  };
  const signal = new AbortController().signal;

  const initial = await postUnifiedSearch(fetcher, payload, signal);
  const refreshed = await postUnifiedSearch(fetcher, payload, signal);

  assert.equal(calls.length, 2);
  assert.equal(calls[1].input, "/api/search");
  assert.equal(calls[1].init.method, "POST");
  assert.deepEqual(JSON.parse(calls[1].init.body), payload);
  assert.deepEqual(await initial.json(), {
    status: "available",
    results: [{ kind: "task", task_id: "task-1" }],
  });
  assert.deepEqual(await refreshed.json(), {
    status: "available",
    results: [{ kind: "task", task_id: "task-2" }],
  });
});

test("refresh nonce advances the request generation and drives the POST effect", () => {
  const componentSource = readFileSync(
    new URL(
      "../../src/components/search/unified-search-client.tsx",
      import.meta.url,
    ),
    "utf8",
  );

  assert.match(
    componentSource,
    /const response = await postUnifiedSearch\(\s*fetch,/,
  );
  assert.match(componentSource, /requestId\.current \+= refreshNonce \+ 1;/);
  assert.match(
    componentSource,
    /\}, \[\s*accessUnavailable,\s*accountId,\s*pageCursor,\s*refreshNonce,[\s\S]*?state,[\s\S]*?viewPreferences\.isLoading,\s*\]\);/,
  );
  assert.equal(
    (
      componentSource.match(
        /setRefreshNonce\(\(current\) => current \+ 1\)/g,
      ) ?? []
    ).length,
    2,
    "retry and focus revalidation must both schedule the POST effect",
  );
});
