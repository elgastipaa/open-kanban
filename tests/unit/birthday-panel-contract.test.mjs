import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const panelSource = await readFile(
  new URL("../../src/components/birthdays/birthday-panel.tsx", import.meta.url),
  "utf8",
);
const taskModalSource = await readFile(
  new URL("../../src/components/board/task-modal.tsx", import.meta.url),
  "utf8",
);
const labelsDialogSource = await readFile(
  new URL(
    "../../src/components/labels/board-labels-dialog.tsx",
    import.meta.url,
  ),
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

test("Series keeps birthday labels editable for birthdays outside the board window", () => {
  assert.match(
    panelSource,
    /active\.birthdays\.map\(\(birthday\) => \[\s*birthday\.board_id,[\s\S]*?slug: birthday\.board_slug/,
    "Series must resolve each birthday's owning board before loading its labels",
  );
  assert.match(
    panelSource,
    /getBoardLabelAssignments\(supabase, board\.slug\)[\s\S]*?listBoardLabels\(supabase, board\.slug\)/,
    "Series must load authorized assignments and the active catalog per board",
  );
  assert.match(
    panelSource,
    /<BoardLabelPicker[\s\S]*?labels=\{editorLabels\}[\s\S]*?selectedIds=\{selectedLabelIds\}/,
    "the existing birthday editor must expose the per-board picker",
  );
  assert.match(
    panelSource,
    /setBirthdayLabels\([\s\S]*?editingBirthday\.board_slug/,
    "tag changes from Series must remain scoped to the birthday's board",
  );
});

test("label restore explains tombstone capacity and the explicit recovery path", () => {
  assert.match(labelsDialogSource, /reason === "task_recovery_limit"/);
  assert.match(labelsDialogSource, /reason === "birthday_recovery_limit"/);
  assert.match(
    labelsDialogSource,
    /Recupera primero desde Series las tareas o cumpleaños en papelera[\s\S]*?desmarca cualquier elemento que ya tenga 10 etiquetas activas/,
    "owners must be told to recover the item and explicitly omit only the over-limit association",
  );
});

test("TaskModal guards close, delete, move, and completion for a dirty label draft", () => {
  const actionWorkflow = taskModalSource.match(
    /function requestTaskAction\([\s\S]*?\n {2}\}/,
  );
  assert.ok(actionWorkflow, "all exits should share one action workflow");
  assert.match(
    actionWorkflow[0],
    /if \(labelsDirty(?: && !options\.labelsResolved)?\)[\s\S]*?setShowLabelCloseChoices\(true\)/,
  );
  assert.match(
    taskModalSource,
    /function requestClose\(\) \{\s*requestTaskAction\("close"\);/,
  );
  assert.match(
    taskModalSource,
    /function requestDelete\(\) \{\s*requestTaskAction\("delete"\);/,
  );
  assert.match(
    taskModalSource,
    /requestTaskAction\("complete", \{ completionTarget: target \}\)/,
  );
  assert.match(
    taskModalSource,
    /requestTaskAction\("move", \{ moveTargetId: targetColumnId \}\)/,
  );
  assert.match(
    taskModalSource,
    /onClose=\{requestClose\}/,
    "Escape and backdrop must reach the guarded close handler",
  );
  assert.match(
    taskModalSource,
    /if \(labelsDirty\) \{\s*setShowCloseChoices\(false\);\s*setShowLabelCloseChoices\(true\);/,
    "field-choice discard must also pass through the label guard",
  );
  assert.match(
    taskModalSource,
    /requestTaskAction\("close", \{ afterSave: true \}\)/,
    "a task save must not bypass a newly dirty label draft",
  );
  assert.match(
    taskModalSource,
    /Guardar etiquetas y continuar[\s\S]*?Descartar etiquetas y continuar[\s\S]*?Seguir editando/,
    "label choices must remain separate from saving task fields",
  );
});

test("stale label conflicts preserve the draft until the user reviews the new baseline", () => {
  const taskSaveLabels = taskModalSource.match(
    /async function saveLabels\(\) \{([\s\S]*?)\n {2}\}/,
  );
  assert.ok(taskSaveLabels);
  const staleTaskResult = taskSaveLabels[1].match(
    /if \([\s\S]*?result\.reason === "stale_selection"[\s\S]*?\) \{([\s\S]*?)\n\s*\}/,
  );
  assert.ok(staleTaskResult, "TaskModal should expose a stale-selection state");
  assert.match(staleTaskResult[1], /setLatestLabelConflict/);
  assert.doesNotMatch(staleTaskResult[1], /setSavedLabelIds/);
  assert.match(
    taskModalSource,
    /function reviewLatestLabelConflict\(\)[\s\S]*?setSavedLabelIds\([\s\S]*?setLatestLabelConflict\(null\)/,
    "only an explicit review action may accept the server baseline",
  );
  assert.match(
    taskModalSource,
    /onSaveLabels\(\s*task\.id,\s*savedLabelIds,\s*selectedLabelIds,?\s*\)/,
    "the retry must compare against the accepted baseline and preserve the draft",
  );

  const staleBirthdayResult = panelSource.match(
    /if \([\s\S]*?result\.reason === "stale_selection"[\s\S]*?\) \{([\s\S]*?)\n\s*\}/,
  );
  assert.ok(
    staleBirthdayResult,
    "BirthdayPanel should expose a stale-selection state",
  );
  assert.match(staleBirthdayResult[1], /setLatestLabelConflict/);
  assert.doesNotMatch(staleBirthdayResult[1], /setSavedLabelIds/);
  assert.match(
    panelSource,
    /function reviewLatestLabelConflict\(\)[\s\S]*?setSavedLabelIds\([\s\S]*?setLatestLabelConflict\(null\)/,
  );
});

test("closing or deleting an edited birthday guards its dirty label draft", () => {
  assert.match(
    panelSource,
    /function requestEditorClose\(\)[\s\S]*?if \(labelsDirty\)[\s\S]*?setShowLabelCloseChoices\(true\)/,
  );
  assert.match(
    panelSource,
    /function requestBirthdayDelete\(\)[\s\S]*?if \(labelsDirty\)[\s\S]*?setShowLabelCloseChoices\(true\)/,
  );
  assert.match(
    panelSource,
    /Guardar etiquetas y continuar[\s\S]*?Descartar etiquetas y continuar[\s\S]*?Seguir editando/,
    "birthday label draft choices must not save the date fields",
  );
  assert.match(
    panelSource,
    /<Modal\s+open=\{editorOpen\}\s+onClose=\{requestEditorClose\}/,
    "Escape and backdrop must use the guarded close path",
  );
  assert.match(
    panelSource,
    /onClick=\{requestBirthdayDelete\}/,
    "delete must use the same dirty-label guard",
  );
  assert.match(
    panelSource,
    /onClick=\{requestEditorClose\}/,
    "Cancel must use the guarded close path",
  );
  const dirtyBirthdaySaveStart = panelSource.indexOf(
    "if (editingBirthday && labelsDirty)",
  );
  const dirtyBirthdaySaveEnd = panelSource.indexOf(
    "setEditorOpen(false);",
    dirtyBirthdaySaveStart,
  );
  assert.ok(
    dirtyBirthdaySaveStart >= 0 &&
      dirtyBirthdaySaveEnd > dirtyBirthdaySaveStart,
  );
  const dirtyBirthdaySave = panelSource.slice(
    dirtyBirthdaySaveStart,
    dirtyBirthdaySaveEnd,
  );
  assert.match(dirtyBirthdaySave, /Las etiquetas siguen como borrador/);
  assert.doesNotMatch(dirtyBirthdaySave, /setEditorOpen\(false\)/);
});
