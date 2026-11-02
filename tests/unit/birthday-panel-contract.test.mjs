import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  createBoardLabelDraft,
  isBoardLabelDraftDirty,
  reconcileBoardLabelCatalogRead,
  reconcileBoardLabelDrafts,
  resolveBoardLabelDraftConflict,
} from "../../src/lib/board-label-edit-state.ts";
import { reconcileRestoreSelection } from "../../src/lib/board-label-restore-state.ts";
import {
  BoardLabelsUnavailableError,
  BoardLabelTrashUnavailableError,
  listBoardLabels,
  listDeletedBoardLabels,
} from "../../src/lib/db/board-labels.ts";

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
const boardSource = await readFile(
  new URL("../../src/components/board/board.tsx", import.meta.url),
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

test("a refreshed label restore preview preserves prior choices and leaves new relations unselected", () => {
  assert.deepEqual(
    reconcileRestoreSelection(
      ["kept-task", "kept-birthday"],
      ["kept-task", "new-over-limit-task", "kept-birthday", "new-task"],
      true,
    ),
    ["kept-task", "kept-birthday"],
  );
  assert.deepEqual(
    reconcileRestoreSelection([], ["first-task", "first-birthday"], false),
    ["first-task", "first-birthday"],
    "the initial preview keeps the existing select-all behavior",
  );

  assert.match(
    labelsDialogSource,
    /setSelectedTasks\(\(current\) =>\s*reconcileRestoreSelection\([\s\S]*?preserveSelections[\s\S]*?\)\)/,
    "a refreshed task preview must reapply only IDs selected before refresh",
  );
  assert.match(
    labelsDialogSource,
    /setSelectedBirthdays\(\(current\) =>\s*reconcileRestoreSelection\([\s\S]*?preserveSelections[\s\S]*?\)\)/,
    "a refreshed birthday preview must reapply only IDs selected before refresh",
  );
});

test("stale label restore requires review against the fresh version before another confirmation", () => {
  const restoreFunction = labelsDialogSource.match(
    /async function confirmRestore\(\) \{([\s\S]*?)\n {2}\}/,
  );
  assert.ok(restoreFunction);
  assert.match(
    restoreFunction[1],
    /expectedVersion:\s*preview\.label(?:\?\.|\.)version/,
    "restore must use the version from the latest preview",
  );
  assert.doesNotMatch(
    restoreFunction[1],
    /expectedVersion:\s*restoreTarget\.version/,
    "the deleted-label list version is stale after a preview conflict",
  );
  assert.match(
    restoreFunction[1],
    /const staleVersion = result\.reason === "stale_version"[\s\S]*?loadPreview\(restoreTarget, restoreName,[\s\S]*?requireReview:\s*staleVersion \|\| restoreNeedsReview/,
    "a conflict loads fresh state and blocks confirmation until review",
  );
  assert.match(
    labelsDialogSource,
    /restoreNeedsReview[\s\S]*?Versión actual:[\s\S]*?Tu propuesta:[\s\S]*?Revisar estado actual y conservar mi propuesta/,
    "the owner can compare the current label with the proposal and explicitly review",
  );
  assert.match(
    labelsDialogSource,
    /!restoreNeedsReview/,
    "another restore must remain disabled until the explicit review action",
  );
  assert.match(
    labelsDialogSource,
    /loadPreview\(restoreTarget, restoreName, \{\s*preserveSelections:\s*true,\s*requireReview:\s*restoreNeedsReview/,
    "updating the preview must not bypass the explicit review action",
  );
});

test("catalog refresh keeps drafts and offers explicit current-version or keep-draft resolution", () => {
  const firstLabel = {
    id: "label-one",
    board_id: "board-one",
    name: "Versión actual uno",
    color: "green",
    version: 4,
  };
  const secondLabel = {
    id: "label-two",
    board_id: "board-one",
    name: "Versión actual dos",
    color: "purple",
    version: 7,
  };
  const firstDraft = {
    name: "Mi propuesta uno",
    color: "red",
    baseName: "Versión inicial uno",
    baseColor: "blue",
    baseVersion: 2,
  };
  const secondDraft = {
    name: "Mi propuesta dos",
    color: "orange",
    baseName: "Versión inicial dos",
    baseColor: "yellow",
    baseVersion: 5,
  };

  assert.equal(isBoardLabelDraftDirty(firstDraft), true);
  assert.deepEqual(
    reconcileBoardLabelDrafts([firstLabel, secondLabel], {
      "label-one": firstDraft,
      "label-two": secondDraft,
    }),
    { "label-one": firstDraft, "label-two": secondDraft },
    "refresh must not erase this label's or another label's local edits",
  );

  assert.deepEqual(
    resolveBoardLabelDraftConflict(firstDraft, firstLabel, "use_current"),
    createBoardLabelDraft(firstLabel),
    "discarding must explicitly replace the draft with the reviewed current version",
  );
  assert.deepEqual(
    resolveBoardLabelDraftConflict(firstDraft, firstLabel, "keep_draft"),
    {
      ...firstDraft,
      baseName: firstLabel.name,
      baseColor: firstLabel.color,
      baseVersion: firstLabel.version,
    },
    "reviewing my changes must keep the proposal over the current version baseline",
  );

  assert.match(
    labelsDialogSource,
    /reconcileBoardLabelCatalogRead\(\{[\s\S]*?previousLabels: editorSnapshotRef\.current\.labels,[\s\S]*?drafts: editorSnapshotRef\.current\.drafts/,
  );
  assert.match(labelsDialogSource, /expectedVersion:\s*draft\.baseVersion/);
  assert.match(
    labelsDialogSource,
    /result\.reason === "stale_version"[\s\S]*?refreshCatalog\(\)[\s\S]*?setLabelConflicts/,
  );
  assert.match(
    labelsDialogSource,
    /Tu edición:[\s\S]*?Versión actual:[\s\S]*?Usar versión actual[\s\S]*?Revisar mis cambios/,
  );
});

test("authorized refresh retains deleted-label drafts, while lost access clears them", () => {
  const deletedLabel = {
    id: "deleted-label",
    board_id: "board-one",
    name: "Etiqueta borrada",
    color: "blue",
    version: 3,
  };
  const activeLabel = {
    id: "active-label",
    board_id: "board-one",
    name: "Etiqueta activa",
    color: "green",
    version: 2,
  };
  const deletedDraft = {
    name: "Mi borrador sin guardar",
    color: "red",
    baseName: deletedLabel.name,
    baseColor: deletedLabel.color,
    baseVersion: deletedLabel.version,
  };
  const activeDraft = {
    name: "Otra propuesta local",
    color: "orange",
    baseName: "Versión anterior",
    baseColor: "yellow",
    baseVersion: 1,
  };

  const authorized = reconcileBoardLabelCatalogRead({
    status: "available",
    slug: "board-one",
    labels: [activeLabel],
    previousLabels: [deletedLabel, activeLabel],
    drafts: { "deleted-label": deletedDraft, "active-label": activeDraft },
    orphanedDrafts: {},
  });
  assert.deepEqual(authorized.drafts, { "active-label": activeDraft });
  assert.deepEqual(authorized.orphanedDrafts, {
    "deleted-label": {
      slug: "board-one",
      label: deletedLabel,
      draft: deletedDraft,
    },
  });

  assert.deepEqual(
    reconcileBoardLabelCatalogRead({ status: "unavailable" }),
    { drafts: {}, orphanedDrafts: {}, pendingConflicts: {} },
    "a catalog read that loses authorization clears every private draft",
  );
});

test("a reappeared label ID requires explicit conflict resolution", () => {
  const label = {
    id: "label-one",
    board_id: "board-one",
    name: "Etiqueta restaurada por owner",
    color: "green",
    version: 4,
  };
  const proposal = {
    name: "Propuesta vieja",
    color: "red",
    baseName: "Etiqueta borrada",
    baseColor: "blue",
    baseVersion: 3,
  };
  const reconciled = reconcileBoardLabelCatalogRead({
    status: "available",
    slug: "board-one",
    labels: [label],
    previousLabels: [],
    drafts: {},
    orphanedDrafts: {
      "label-one": {
        slug: "board-one",
        label: {
          ...label,
          name: "Etiqueta borrada",
          color: "blue",
          version: 3,
        },
        draft: proposal,
      },
    },
  });
  assert.deepEqual(reconciled.pendingConflicts, {
    "label-one": { current: label, proposal },
  });
  assert.equal(reconciled.drafts["label-one"].name, label.name);
  assert.deepEqual(reconciled.orphanedDrafts, {});
  assert.match(
    labelsDialogSource,
    /editorState\.pendingConflicts[\s\S]*?setLabelConflicts/,
  );
  const saveLabelBody = labelsDialogSource.match(
    /async function saveLabel\(label: BoardLabel\) \{[\s\S]*?\n {2}\}/,
  );
  assert.ok(saveLabelBody);
  assert.match(
    saveLabelBody[0],
    /if \(!draft \|\| labelConflicts\[label\.id\] \|\| loading\) return/,
  );
  assert.match(
    labelsDialogSource,
    /Tu edición:[\s\S]*?Versión actual:[\s\S]*?Usar versión actual[\s\S]*?Revisar mis cambios/,
  );
  assert.match(
    labelsDialogSource,
    /Promise\.allSettled\([\s\S]*?applyActiveCatalog\(activeResult\.value\)/,
    "opening the dialog must reconcile the retained orphan draft with the current catalog",
  );
});

test("closing label administration retains drafts and board filters", () => {
  assert.match(
    labelsDialogSource,
    /reconcileBoardLabelCatalogRead\(\{\s*status: "available"[\s\S]*?orphanedDrafts/,
  );
  assert.match(
    labelsDialogSource,
    /clearPrivateCatalogContent = useCallback\(\(\) => \{[\s\S]*?clearDialogDrafts\(\)[\s\S]*?onLabelsChange\(\[\]\)/,
  );
  assert.match(
    labelsDialogSource,
    /failure instanceof BoardLabelsUnavailableError[\s\S]*?clearPrivateCatalogContent\(\)/,
    "an authoritative access denial clears private UI state",
  );
  const closeHandler = labelsDialogSource.match(
    /function handleClose\(\) \{[\s\S]*?\n {2}\}/,
  );
  assert.ok(closeHandler, "closing the dialog has a dedicated close path");
  assert.match(closeHandler[0], /onClose\(\)/);
  assert.doesNotMatch(
    closeHandler[0],
    /clearDialogDrafts|clearPrivateCatalogContent|onLabelsChange|setDrafts|setOrphanedDrafts|setLabelConflicts|setPreview/,
  );
  assert.match(labelsDialogSource, /<Modal[\s\S]*?onClose=\{handleClose\}/);
  assert.match(boardSource, /const \[selectedLabelIds, setSelectedLabelIds\]/);
  assert.match(boardSource, /onLabelsChange=\{handleBoardLabelsChange\}/);
  assert.doesNotMatch(closeHandler[0], /setSelectedLabelIds|setBoardLabels/);
});

test("unavailable RPC clears access state while transport errors retain edits", () => {
  assert.match(
    labelsDialogSource,
    /async function reconcileUnavailableResult\([\s\S]*?refreshCatalog\(\)[\s\S]*?BoardLabelsUnavailableError/,
    "the result is resolved through a current authorized catalog read before cleanup",
  );
  for (const flow of [
    "saveLabel",
    "confirmDelete",
    "loadPreview",
    "confirmRestore",
  ]) {
    const flowBody = labelsDialogSource.match(
      new RegExp(`(?:async )?function ${flow}\\([\\s\\S]*?\\n  \\}`),
    );
    assert.ok(flowBody, `${flow} should exist`);
    assert.match(flowBody[0], /reconcileUnavailableResult\(/);
  }
  const saveLabelBody = labelsDialogSource.match(
    /async function saveLabel\(label: BoardLabel\) \{[\s\S]*?\n {2}\}/,
  );
  assert.ok(saveLabelBody);
  const transportFailure = saveLabelBody[0].match(
    /catch \(failure\) \{([\s\S]*?)\n {4}\}/,
  );
  assert.ok(transportFailure, "save errors have a transport failure path");
  assert.match(transportFailure[0], /conservamos los cambios escritos/i);
  assert.match(transportFailure[0], /reintent/);
  assert.doesNotMatch(transportFailure[0], /clearPrivateCatalogContent/);
  assert.match(transportFailure[0], /setError/);
  assert.match(
    labelsDialogSource,
    /catalogReadFailed \|\| trashReadFailed[\s\S]*?Reintentar lectura/,
  );
  assert.match(
    labelsDialogSource,
    /catch \(failure\)[\s\S]*?failure instanceof BoardLabelsUnavailableError[\s\S]*?clearPrivateCatalogContent/,
  );
  assert.match(boardSource, /const \[selectedLabelIds, setSelectedLabelIds\]/);
});

test("catalog RPC unavailability is distinct from transport and parse errors", async () => {
  await assert.rejects(
    listBoardLabels(
      {
        rpc: async () => ({ data: { status: "unavailable" }, error: null }),
      },
      "board-one",
    ),
    BoardLabelsUnavailableError,
  );
  await assert.rejects(
    listBoardLabels(
      {
        rpc: async () => ({
          data: null,
          error: new Error("temporary network"),
        }),
      },
      "board-one",
    ),
    (error) =>
      error instanceof Error && !(error instanceof BoardLabelsUnavailableError),
  );
  await assert.rejects(
    listBoardLabels(
      {
        rpc: async () => ({
          data: { status: "available", labels: "malformed" },
          error: null,
        }),
      },
      "board-one",
    ),
    (error) =>
      error instanceof Error && !(error instanceof BoardLabelsUnavailableError),
  );
});

test("trash unavailable is distinct from transport and parse errors", async () => {
  await assert.rejects(
    listDeletedBoardLabels(
      {
        rpc: async () => ({ data: { status: "unavailable" }, error: null }),
      },
      "board-one",
    ),
    BoardLabelTrashUnavailableError,
  );
  await assert.rejects(
    listDeletedBoardLabels(
      {
        rpc: async () => ({
          data: null,
          error: new Error("temporary network"),
        }),
      },
      "board-one",
    ),
    (error) =>
      error instanceof Error &&
      !(error instanceof BoardLabelTrashUnavailableError),
  );
  await assert.rejects(
    listDeletedBoardLabels(
      {
        rpc: async () => ({
          data: { status: "available", labels: "malformed" },
          error: null,
        }),
      },
      "board-one",
    ),
    (error) =>
      error instanceof Error &&
      !(error instanceof BoardLabelTrashUnavailableError),
  );
  assert.match(labelsDialogSource, /trashReadFailed/);
  assert.match(
    labelsDialogSource,
    /trashResult\.reason instanceof BoardLabelTrashUnavailableError[\s\S]*?setTrash\(\[\]\)[\s\S]*?else \{[\s\S]*?setTrashReadFailed\(true\)/,
    "an authoritative unavailable result may clear trash, while transient failures keep it",
  );
  assert.match(
    labelsDialogSource,
    /catch \(failure\) \{[\s\S]*?failure instanceof BoardLabelTrashUnavailableError[\s\S]*?setTrash\(\[\]\)[\s\S]*?else \{[\s\S]*?setTrashReadFailed\(true\)[\s\S]*?Conservamos su último estado/,
    "refresh errors preserve the last trash snapshot and expose retry",
  );
  assert.match(
    labelsDialogSource,
    /catalogReadFailed \|\| trashReadFailed[\s\S]*?retryCatalogRead/,
    "a failed trash read can be retried from the dialog",
  );
  assert.doesNotMatch(
    labelsDialogSource,
    /listDeletedBoardLabels\(supabase, slug\)\.catch\(\(\) => \[\]\)/,
  );
});

test("orphan label drafts remain visible and discard-only", () => {
  assert.match(
    labelsDialogSource,
    /Etiqueta ya no disponible[\s\S]*?No se reenviará automáticamente/,
    "orphan drafts must never be silently converted into mutations",
  );
  const orphanSection = labelsDialogSource.match(
    /\{visibleOrphanedDrafts\.length > 0 \? \([\s\S]*?\) : null\}/,
  );
  assert.ok(orphanSection, "authorized users can see retained orphan drafts");
  assert.match(orphanSection[0], /Descartar borrador/);
  assert.doesNotMatch(orphanSection[0], /Guardar|updateBoardLabel\(/);
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
