import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const panelSource = await readFile(
  new URL("../../src/components/birthdays/birthday-panel.tsx", import.meta.url),
  "utf8",
);

test("birthday advance is capped at one annual window in validation and input", () => {
  assert.ok(
    /Number\.isInteger\(parsed\)\s*\|\|\s*parsed < 0\s*\|\|\s*parsed > 366/.test(
      panelSource,
    ),
    "the input parser must reject values above 366 days",
  );
  assert.ok(
    /id=\{advanceId\}[\s\S]*?min=\{0\}[\s\S]*?max=\{366\}/.test(panelSource),
    "the numeric input must expose the 366-day limit",
  );
});

test("a board time-zone change triggers the existing birthday refresh effect", () => {
  const refreshDependencies = panelSource.match(
    /const refresh = useCallback\(async \(\) => \{[\s\S]*?\n {2}\}, \[([^\]]+)\]\);/,
  );
  assert.ok(refreshDependencies, "the birthday refresh callback should exist");
  assert.ok(
    /\bboardTimeZone\b/.test(refreshDependencies[1]),
    "boardTimeZone must recreate the refresh callback",
  );
  assert.ok(
    /useEffect\(\(\) => \{\s*void refresh\(\);\s*\}, \[refresh\]\);/.test(
      panelSource,
    ),
    "the refresh effect must fetch when that callback changes",
  );
});
