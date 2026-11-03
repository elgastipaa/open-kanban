import assert from "node:assert/strict";
import { test } from "node:test";
import { compareBoardImportHeaders } from "../../src/lib/portable-board-import-preview.ts";

test("v2 preview compares destination and proposed name and time zone", () => {
  assert.deepEqual(
    compareBoardImportHeaders(
      {
        name: "Tablero destino",
        time_zone: "UTC",
      },
      {
        name: "Respaldo completo",
        time_zone: "America/Argentina/Buenos_Aires",
      },
    ),
    [
      {
        label: "Nombre del tablero",
        current: "Tablero destino",
        proposed: "Respaldo completo",
      },
      {
        label: "Zona horaria",
        current: "UTC",
        proposed: "America/Argentina/Buenos_Aires",
      },
    ],
  );
});
