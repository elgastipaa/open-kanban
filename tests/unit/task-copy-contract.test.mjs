import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const actionSource = await readFile(
  new URL("../../src/components/board/task-copy-action.tsx", import.meta.url),
  "utf8",
);
const taskModalSource = await readFile(
  new URL("../../src/components/board/task-modal.tsx", import.meta.url),
  "utf8",
);
const seriesPageSource = await readFile(
  new URL("../../src/app/series/page.tsx", import.meta.url),
  "utf8",
);
const birthdayPanelSource = await readFile(
  new URL("../../src/components/birthdays/birthday-panel.tsx", import.meta.url),
  "utf8",
);

test("TaskModal exposes copy only for the saved authorized source", () => {
  assert.match(
    taskModalSource,
    /<TaskCopyAction[\s\S]*?slug=\{slug\}[\s\S]*?sourceTaskId=\{baseTask\.id\}/,
    "the copy action must use the current saved task identity",
  );
  assert.match(
    taskModalSource,
    /disabled=\{[\s\S]*?dirty[\s\S]*?labelsDirty[\s\S]*?isSessionStale[\s\S]*?\}/,
    "unsaved edits, label drafts, and stale authorization must block preparing a copy",
  );
});

test("the action shows a same-board preview and asks for review after content changes", () => {
  assert.match(actionSource, /title="Duplicar tarea puntual"/);
  assert.match(actionSource, /label="Título"/);
  assert.match(actionSource, /Columna de destino/);
  assert.match(
    actionSource,
    /columns\.map\(\(column\) => \(/,
    "the target list must come from the authorized source board",
  );
  assert.match(
    actionSource,
    /Prioridad:[\s\S]*?pasos sin[\s\S]*?etiquetas activas/,
  );
  assert.match(
    actionSource,
    /No se copiarán responsable, fecha límite, conversación ni\s*archivos/,
  );
  assert.match(
    actionSource,
    /Si el origen\s*es una ocurrencia, la copia será puntual y no cambiará la serie/,
  );
  assert.match(
    actionSource,
    /receiveTaskCopyPreview\(current, refreshedPreview\)/,
  );
  assert.match(actionSource, /conservamos el título y el destino que elegiste/);
  assert.match(actionSource, /Revisé la vista previa actualizada/);
  assert.match(actionSource, /!canCreateTaskCopy\(form\)/);
  assert.match(actionSource, /Abrir copia/);
});

test("cancel closes the preview without submitting a copy", () => {
  const closeHandler = actionSource.match(
    /function closeCopy\(\) \{([\s\S]*?)\n {2}\}/,
  );
  assert.ok(closeHandler);
  assert.match(closeHandler[1], /setIsOpen\(false\)/);
  assert.doesNotMatch(closeHandler[1], /copyTask|submitCopy/);
  assert.match(
    actionSource,
    /<Button variant="ghost" onClick=\{closeCopy\} disabled=\{isSaving\}>\s*Cancelar/,
  );
});

test("uncertain copy retries the same operation and unknown expiry blocks a new copy", () => {
  assert.match(actionSource, /setPendingCommand\(copyCommand\)/);
  assert.match(
    actionSource,
    /function retryCopy\(\) \{\s*if \(!pendingCommand\) return;\s*void submitCopy\(pendingCommand\);/,
    "retry must reuse the exact command and operation ID",
  );
  assert.match(actionSource, /Reintentar la misma operación/);
  assert.match(actionSource, /result\.status === "expired_unknown"/);
  assert.match(actionSource, /Revisar el tablero/);
  assert.match(actionSource, /isExpiredUnknown \|\|/);
});

test("series history offers copy only for a currently available occurrence", () => {
  assert.match(
    seriesPageSource,
    /occurrenceDetail\?\.occurrence\?\.content_available/,
    "historical task content must still be available and authorized",
  );
  assert.match(
    seriesPageSource,
    /copyPreview\?\.status === "available" && detailTask/,
    "an unavailable or deleted source must not display the copy action",
  );
  assert.doesNotMatch(
    birthdayPanelSource,
    /TaskCopyAction|previewTaskCopy|copyTask/,
    "birthday entities must not offer task duplication",
  );
});
