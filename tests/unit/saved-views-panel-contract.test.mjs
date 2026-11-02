import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const panelSource = await readFile(
  new URL(
    "../../src/components/saved-views/saved-views-panel.tsx",
    import.meta.url,
  ),
  "utf8",
);

test("changing the selected view cannot replay the initial server snapshot", () => {
  const snapshotEffect = panelSource.match(
    /useEffect\(\(\) => \{[\s\S]*?initialSnapshot\.status === "available"[\s\S]*?\n {2}\}, \[([^\]]+)\]\);/,
  );

  assert.ok(
    snapshotEffect,
    "the initial snapshot synchronization effect exists",
  );
  assert.doesNotMatch(
    snapshotEffect[1],
    /\bselectedId\b|\bdeletedId\b/,
    "catalog selection changes must not replay the stale initial snapshot",
  );
});

test("choosing a saved view selects its server name while preserving the explicit reset action", () => {
  assert.match(
    panelSource,
    /const nextId = event\.target\.value;[\s\S]*?setSelectedId\(nextId\);[\s\S]*?setName\([\s\S]*?activeViews\.find\(\(view\) => view\.id === nextId\)\?\.name \?\? ""/,
  );
  assert.match(
    panelSource,
    /onClick=\{\(\) => onApply\(selectedView\.definition\)\}[\s\S]*?>\s*Restablecer vista/,
  );
});
