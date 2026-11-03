import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const repetitionSource = await readFile(
  new URL("../../src/components/board/task-repetition.tsx", import.meta.url),
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
const labelDbSource = await readFile(
  new URL("../../src/lib/db/board-labels.ts", import.meta.url),
  "utf8",
);
const migrationSource = await readFile(
  new URL(
    "../../supabase/migrations/056_repetition_template_labels.sql",
    import.meta.url,
  ),
  "utf8",
);

test("the repetition editor exposes a distinct, explicitly saved future-label selection", () => {
  assert.match(
    taskModalSource,
    /<TaskRepetition[\s\S]*?onSetTemplateLabels=\{onSetRepetitionTemplateLabels\}/,
    "the authorized task editor must pass the independent template mutation",
  );
  assert.match(
    repetitionSource,
    /legend="Etiquetas de próximas tarjetas"/,
    "the selector must distinguish the template from this occurrence",
  );
  assert.match(
    repetitionSource,
    /Esta selección es independiente de las etiquetas de la\s*tarjeta actual\. Solo se copia en ocurrencias nuevas\./,
    "the UI must state the no-retroactive behavior",
  );
  assert.match(
    repetitionSource,
    /onSetTemplateLabels\(task\.id, expected, requested\)/,
    "the template selection must use its own CAS mutation",
  );
  assert.match(
    repetitionSource,
    /Guardar etiquetas de próximas tarjetas/,
    "future-label changes must have an explicit save action",
  );
});

test("a stale template-label selection keeps the draft until explicit review", () => {
  const save = repetitionSource.match(
    /async function saveTemplateLabels\(\) \{([\s\S]*?)\n {2}\}/,
  );
  assert.ok(save, "template labels must use a dedicated save workflow");
  assert.match(save[1], /result\.reason === "stale_selection"/);
  assert.match(save[1], /setTemplateLabelConflict\(/);
  assert.match(save[1], /templateLabelIds\.length > 10/);
  assert.match(
    repetitionSource,
    /Revisar selección actual y conservar mi propuesta/,
    "the user must explicitly review the current set before another save",
  );
  assert.match(
    repetitionSource,
    /setTemplateLabelBaseline\(templateLabelConflict\)[\s\S]*?setTemplateLabelConflict\(null\)/,
    "review rebases the expected set without replacing the user's draft",
  );
});

test("restoring a tag includes repetition templates in preview and explicit selection", () => {
  assert.match(
    labelDbSource,
    /preview_restore_board_label_with_series_p/,
    "the UI preview must include template associations",
  );
  assert.match(
    labelDbSource,
    /restore_board_label_with_series_p/,
    "the UI confirmation must use the explicit series selection",
  );
  assert.match(
    labelsDialogSource,
    /title="Plantillas de próximas repeticiones"[\s\S]*?selectedIds=\{selectedSeries\}[\s\S]*?onChange=\{setSelectedSeries\}/,
    "owners must be able to omit an over-cap template association explicitly",
  );
  assert.match(
    labelsDialogSource,
    /selectedSeries\.includes\(item\.id\)/,
    "selected over-limit series must block confirmation",
  );
  assert.match(
    migrationSource,
    /'omitted_series_ids', to_jsonb/,
    "the atomic restore result must state which template relation was omitted",
  );
});
