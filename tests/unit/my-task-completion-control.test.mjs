import assert from "node:assert/strict";
import { test } from "node:test";
import { getMyTaskCompletionControl } from "../../src/lib/my-task-completion-control.ts";

test("completed personal tasks expose a static accessible status, not reopen", () => {
  assert.deepEqual(getMyTaskCompletionControl(true, "Revisar presupuesto"), {
    kind: "status",
    label: "Completada",
    accessibleLabel: "Tarea completada: Revisar presupuesto",
  });
});

test("pending personal tasks expose only the complete action", () => {
  assert.deepEqual(getMyTaskCompletionControl(false, "Revisar presupuesto"), {
    kind: "action",
    label: "Completar",
    accessibleLabel: "Completar tarea: Revisar presupuesto",
  });
});
