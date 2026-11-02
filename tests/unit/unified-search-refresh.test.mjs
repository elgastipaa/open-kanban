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

test("search preference controls are disabled while their save or conflict is unresolved", () => {
  const componentSource = readFileSync(
    new URL(
      "../../src/components/search/unified-search-client.tsx",
      import.meta.url,
    ),
    "utf8",
  );

  assert.match(
    componentSource,
    /function isPreferenceBlocked\(key: string\)[\s\S]*?state\.saving\[key\][\s\S]*?state\.conflicts\[key\]/,
  );
  assert.match(
    componentSource,
    /function preferenceControlProps\(key: string\)[\s\S]*?disabled,[\s\S]*?"aria-busy"[\s\S]*?"aria-describedby"/,
  );
  for (const [id, key] of [
    ["search-board-filter", "filter_board"],
    ["search-priority", "filter_priority"],
    ["search-due", "filter_due"],
    ["search-assignee", "filter_responsibility"],
  ]) {
    assert.match(
      componentSource,
      new RegExp(
        `id="${id}"[\\s\\S]*?\\{\\.\\.\\.preferenceControlProps\\("${key}"\\)\\}`,
      ),
    );
  }
  assert.match(
    componentSource,
    /checked=\{state\.includeCompleted\}[\s\S]*?\.\.\.preferenceControlProps\("include_completed"\)/,
  );
  assert.match(
    componentSource,
    /checked=\{state\.includeHistory\}[\s\S]*?\.\.\.preferenceControlProps\("include_history"\)/,
  );
  assert.match(
    componentSource,
    /\.\.\.preferenceControlProps\("filter_labels"\)/,
  );
  assert.match(
    componentSource,
    /value=\{state\.order\}[\s\S]*?\.\.\.preferenceControlProps\("order"\)/,
  );
  assert.match(componentSource, /isClearBlocked/);
  assert.match(
    componentSource,
    /Guardando preferencias de búsqueda[\s\S]*?controles afectados están deshabilitados/,
  );
});
