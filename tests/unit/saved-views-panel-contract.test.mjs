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

test("a catalog refresh surfaces newer versions and blocks updates until review", () => {
  const refresh = panelSource.match(
    /const refresh = useCallback\(async \(\) => \{([\s\S]*?)\n {2}\}, \[/,
  );
  const update = panelSource.match(
    /async function handleUpdate\(\) \{([\s\S]*?)\n {2}\}/,
  );

  assert.ok(refresh, "the authorized refresh action exists");
  assert.ok(update, "the explicit update action exists");
  assert.match(
    refresh[1],
    /detectSavedViewVersionChange\(\s*activeViewsRef\.current,\s*active,\s*nextSelectedId === selectedId \? selectedId : "",\s*\)/,
    "refresh must compare the selected version before adopting the catalog",
  );
  assert.match(
    update[1],
    /updateConflict/,
    "an unresolved remote-version conflict must block mutation",
  );
  assert.match(
    panelSource,
    /disabled=\{[\s\S]*?!currentDefinitionValid[\s\S]*?Boolean\(updateConflict\)\s*\}/,
    "the UI must disable Update while the remote version is unresolved",
  );
  assert.match(
    panelSource,
    /disabled=\{\s*selectedView\.needs_review\s*\|\|\s*busy\s*\|\|\s*Boolean\(updateConflict\)\s*\}/,
    "applying the selected view must wait for an explicit conflict choice",
  );
});
