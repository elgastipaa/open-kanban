import assert from "node:assert/strict";
import { test } from "node:test";
import {
  describeTaskActivityEvent,
  taskActivityActorLabel,
} from "../../src/lib/task-activity-state.ts";

test("activity labels distinguish local actors, system, and imported history", () => {
  assert.equal(taskActivityActorLabel("user", "Ana"), "Ana");
  assert.equal(taskActivityActorLabel("system", null), "Sistema");
  assert.equal(
    taskActivityActorLabel("imported", "Ana"),
    "Actividad importada · Ana",
  );
  assert.equal(
    taskActivityActorLabel("imported", "Importado"),
    "Actividad importada · Importado",
  );
  assert.equal(taskActivityActorLabel("imported", null), "Actividad importada");
});

test("activity descriptions stay within E05 fields and show before/after", () => {
  assert.deepEqual(
    describeTaskActivityEvent({
      category: "assignee",
      before_value: "Sin responsable",
      after_value: "Ana",
    }),
    { label: "Responsable", value: "Sin responsable → Ana" },
  );
  assert.deepEqual(
    describeTaskActivityEvent({
      category: "due_date",
      before_value: null,
      after_value: "2026-11-03",
    }),
    { label: "Fecha límite", value: "Sin fecha → 3 de nov de 2026" },
  );
  assert.deepEqual(
    describeTaskActivityEvent({
      category: "completion",
      before_value: false,
      after_value: true,
    }),
    { label: "Estado", value: "Pendiente → Completada" },
  );
  assert.deepEqual(
    describeTaskActivityEvent({
      category: "recovery",
      before_value: null,
      after_value: null,
    }),
    { label: "Recuperación", value: "Tarea recuperada" },
  );
});
