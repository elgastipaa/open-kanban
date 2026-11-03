import assert from "node:assert/strict";
import test from "node:test";
import {
  beginThemePreferenceChange,
  createThemePreferenceState,
  resolveThemePreferenceConflict,
  settleThemePreferenceSave,
} from "../../src/lib/theme-preference-state.ts";

test("a person starts in System until an account preference exists", () => {
  assert.deepEqual(createThemePreferenceState("person-a"), {
    accountId: "person-a",
    theme: "system",
    version: 0,
    isSaving: false,
    error: null,
    conflict: null,
    loadFailed: false,
  });
});

test("the local theme remains active when the saved version changed elsewhere", () => {
  const local = beginThemePreferenceChange(
    createThemePreferenceState("person-a", { theme: "system", version: 1 }),
    "light",
  );
  const conflict = settleThemePreferenceSave(local, {
    status: "conflict",
    theme: "dark",
    version: 4,
  });

  assert.equal(conflict.theme, "light");
  assert.deepEqual(conflict.conflict, { theme: "dark", version: 4 });
  assert.equal(conflict.isSaving, false);

  const loaded = resolveThemePreferenceConflict(conflict, "load-saved");
  assert.equal(loaded.theme, "dark");
  assert.equal(loaded.version, 4);
  assert.equal(loaded.conflict, null);
});

test("keeping the reviewed local theme retries against the saved version", () => {
  const conflict = settleThemePreferenceSave(
    beginThemePreferenceChange(
      createThemePreferenceState("person-a", { theme: "system", version: 1 }),
      "light",
    ),
    { status: "conflict", theme: "dark", version: 4 },
  );
  const review = resolveThemePreferenceConflict(conflict, "keep-local");

  assert.deepEqual(review.command, { theme: "light", expectedVersion: 4 });
  assert.equal(review.state.theme, "light");
  assert.equal(review.state.version, 4);
  assert.equal(review.state.isSaving, true);

  const saved = settleThemePreferenceSave(review.state, {
    status: "saved",
    theme: "light",
    version: 5,
  });
  assert.equal(saved.theme, "light");
  assert.equal(saved.version, 5);
  assert.equal(saved.conflict, null);
});

test("a save error keeps the local choice and reports that it is not synchronized", () => {
  const local = beginThemePreferenceChange(
    createThemePreferenceState("person-a", { theme: "system", version: 1 }),
    "dark",
  );
  const failed = settleThemePreferenceSave(local, { status: "error" });

  assert.equal(failed.theme, "dark");
  assert.equal(failed.version, 1);
  assert.equal(
    failed.error,
    "No se pudo sincronizar el tema. Inténtalo de nuevo.",
  );
  assert.equal(failed.isSaving, false);
});

test("changing accounts clears the prior person's local and conflict state", () => {
  const conflict = settleThemePreferenceSave(
    beginThemePreferenceChange(
      createThemePreferenceState("person-a", { theme: "system", version: 1 }),
      "light",
    ),
    { status: "conflict", theme: "dark", version: 3 },
  );
  const secondPerson = createThemePreferenceState("person-b", {
    theme: "system",
    version: 0,
  });

  assert.notEqual(secondPerson.accountId, conflict.accountId);
  assert.equal(secondPerson.theme, "system");
  assert.equal(secondPerson.conflict, null);
});
