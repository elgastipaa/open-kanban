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
const searchSource = await readFile(
  new URL(
    "../../src/components/search/unified-search-client.tsx",
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

test("reviewing a revoked board scope stays blocked instead of broadening to all boards", () => {
  const apply = searchSource.match(
    /async function applySavedView\(([\s\S]*?)\n {2}\}/,
  );

  assert.ok(apply, "saved search definitions have one application seam");
  assert.match(
    apply[1],
    /boardScopeNeedsReplacement[\s\S]*?setPendingSavedViewReview\(\{[\s\S]*?boardScopeNeedsReplacement[\s\S]*?\}\)[\s\S]*?setResults\(\[\]\)[\s\S]*?return;/,
    "a revoked board reference must block results and preserve its definition for explicit replacement",
  );
  assert.match(
    searchSource,
    /pendingSavedViewReview[\s\S]*?replacementBoard\.id[\s\S]*?invalidReferences\.filter\(\(field\) => field !== "boardId"\)/,
    "only an explicit accessible-board choice may replace the saved scope",
  );
  assert.doesNotMatch(
    apply[1],
    /invalidReferences\.includes\("boardId"\)[\s\S]*?\?\s*"all"/,
    "review must never silently widen a board-only view",
  );
});

test("a pending board-scope review exposes the replacement control but pauses searches", () => {
  assert.match(
    searchSource,
    /scopeUnavailable\s*&&\s*!pendingSavedViewReview/,
    "the unavailable-board placeholder must not hide the explicit replacement control",
  );
  assert.match(
    searchSource,
    /accessUnavailable\s*\|\|\s*scopeUnavailable\s*\|\|\s*pendingSavedViewReview\s*\|\|\s*viewPreferences\.isLoading/,
    "a saved view must not submit or expose results before its scope is reviewed",
  );
  assert.match(
    searchSource,
    /id="unified-search-query"[\s\S]*?disabled=\{Boolean\(pendingSavedViewReview\)\}/,
    "query editing must wait until the saved scope is explicitly reviewed",
  );
  assert.match(
    searchSource,
    /const disabled =\s*Boolean\(pendingSavedViewReview\)\s*\|\|\s*isPreferenceBlocked\(key\)/,
    "filter and preference controls must pause with the query",
  );
  assert.match(
    searchSource,
    /unavailableReferenceActionLabel\(field\)[\s\S]*?removeUnavailableViewCondition\(field\)/,
    "review offers a generic explicit action for each invalid reference family",
  );
  assert.match(
    searchSource,
    /disabled=\{Boolean\(pendingSavedViewReview\)\}[\s\S]*?onClick=\{\(\) => changeScope\("all", null\)\}/,
    "the direct widen-to-all action must not bypass pending review",
  );
});

const silentlyRemovedReferences = [
  [
    "filterBoardId",
    /filterBoardId:\s*invalidReferences\.includes\("filterBoardId"\)\s*\?\s*null/,
  ],
  [
    "assigneeId",
    /assigneeId:\s*invalidReferences\.includes\("assigneeId"\)\s*\?\s*null/,
  ],
  [
    "labels",
    /labelFilters:\s*invalidReferences\.includes\("labels"\)\s*\?\s*\[\]/,
  ],
];

for (const [field, pattern] of silentlyRemovedReferences) {
  test(`invalid ${field} references stay in the proposal until an explicit review choice`, () => {
    const apply = searchSource.match(
      /async function applySavedView\(([\s\S]*?)\n {2}\}/,
    );

    assert.ok(apply, "saved search definitions have one application seam");
    assert.doesNotMatch(
      apply[1],
      pattern,
      `${field} must not be cleared as a side effect of opening review`,
    );
    assert.match(
      apply[1],
      /invalidReferences\.length\s*>\s*0[\s\S]*?setPendingSavedViewReview[\s\S]*?return;/,
      "any remaining invalid field must block loading and results",
    );
  });
}
