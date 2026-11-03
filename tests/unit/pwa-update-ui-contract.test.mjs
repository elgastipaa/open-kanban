import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const provider = readFileSync(
  new URL("../../src/components/pwa/pwa-provider.tsx", import.meta.url),
  "utf8",
);
const taskModal = readFileSync(
  new URL("../../src/components/board/task-modal.tsx", import.meta.url),
  "utf8",
);

test("the waiting update is announced and only an explicit choice activates it", () => {
  assert.match(provider, /Hay una actualización disponible\./);
  assert.match(provider, /Recargar para actualizar/);
  assert.match(provider, /requestPwaUpdate\(updateGuardRegistry, activate\)/);
  assert.match(provider, /waitingWorker\?\.postMessage\(\{ type: "ACTIVATE_UPDATE" \}\)/);
  assert.match(
    provider,
    /if \(!updateApplyingRef\.current\) return;[\s\S]+window\.location\.reload\(\)/,
  );
});

test("an active draft offers save, discard, or continue before activation", () => {
  assert.match(taskModal, /if \(!dirty && !labelsDirty\) return false;/);
  assert.match(taskModal, /Guardar y actualizar/);
  assert.match(taskModal, /Descartar cambios y actualizar/);
  assert.match(taskModal, /Seguir editando/);
  assert.match(taskModal, /Guardar etiquetas y actualizar/);
});

test("save errors and conflicts keep the update prompt and restore save focus", () => {
  assert.match(
    taskModal,
    /if \(result\.status === "conflict"\)[\s\S]+setShowCloseChoices\(pendingUpdateActivationRef\.current !== null\);[\s\S]+restoreUpdateResolutionSaveFocus\(\)/,
  );
  assert.match(
    taskModal,
    /catch \(error\)[\s\S]+setShowCloseChoices\(pendingUpdateActivationRef\.current !== null\);[\s\S]+restoreUpdateResolutionSaveFocus\(\)/,
  );
  assert.match(
    taskModal,
    /function saveLabelsAndContinue\(\)[\s\S]+if \(await saveLabels\(\)\) \{[\s\S]+continueAfterLabelResolution\("save"\);[\s\S]+restoreUpdateResolutionSaveFocus\(\)/,
  );
  assert.match(
    taskModal,
    /updateResolutionSaveFocusRef\.current = target;[\s\S]+updateResolutionSaveFocusRef\.current = null;[\s\S]+if \(!target\.disabled\)[\s\S]+button\.textContent\?\.trim\(\) === "Seguir editando"[\s\S]+\.focus\(\{ preventScroll: true \}\)/,
  );
});

test("a save must be confirmed before its deferred update continuation runs", () => {
  const saveFlow = taskModal.slice(
    taskModal.indexOf("async function save("),
    taskModal.indexOf("async function reconcileExpiredOperation()"),
  );
  const catchBlock = saveFlow.slice(saveFlow.indexOf("catch (error)"));

  assert.match(
    saveFlow,
    /const result = await onSave\(operation\);[\s\S]+if \(result\.status !== "confirmed"\)[\s\S]+throw new Error\(/,
  );
  assert.doesNotMatch(catchBlock, /resolvePendingUpdate\("save", "confirmed"\)/);
});

test("another tab may activate the worker, but this tab still needs an explicit guarded reload", () => {
  const controllerChangeFlow = provider.slice(
    provider.indexOf("const onControllerChange = () => {"),
    provider.indexOf("const onVisibilityChange = () => {"),
  );
  assert.match(provider, /const updateWasWaitingRef = useRef\(false\)/);
  assert.match(
    provider,
    /const updateWasWaiting = updateWasWaitingRef\.current;[\s\S]+if \(updateWasWaiting && !registration\?\.waiting\)[\s\S]+updateActivatedElsewhereRef\.current = true;[\s\S]+setUpdateAvailable\(true\)/,
  );
  assert.match(
    provider,
    /const activate = \(\) => \{[\s\S]+const waitingWorker = registrationRef\.current\?\.waiting \?\? null;[\s\S]+getPwaUpdateTarget\([\s\S]+updateActivatedElsewhereRef\.current[\s\S]+updateTarget === "active"[\s\S]+window\.location\.reload\(\)[\s\S]+requestPwaUpdate\(updateGuardRegistry, activate\)/,
  );
  assert.match(controllerChangeFlow, /setUpdateAvailable\(true\)/);
  assert.match(controllerChangeFlow, /reloadAfterActivation\(\)/);
  assert.doesNotMatch(controllerChangeFlow, /window\.location\.reload\(\)/);
  assert.match(
    provider,
    /const reloadAfterActivation = \(\) => \{\s*if \(!updateApplyingRef\.current\) return;[\s\S]+window\.location\.reload\(\)/,
  );
});
