import assert from "node:assert/strict";
import test from "node:test";
import {
  MAX_LEGACY_BOARD_IMPORT_BYTES,
  parseLegacyBoardImport,
  validateLegacyBoardImportSize,
} from "../../src/lib/legacy-board-import.ts";

function legacyDocument(overrides = {}) {
  return {
    version: 1,
    exportedAt: "2026-11-02T12:00:00.000Z",
    board: {
      slug: "source-board",
      columns: [
        {
          title: "  Pendientes  ",
          position: 0,
          tasks: [
            {
              title: "  Revisar respaldo  ",
              description: null,
              priority: "high",
              position: 0,
            },
          ],
        },
      ],
    },
    ...overrides,
  };
}

test("legacy v1 maps only portable columns and tasks with explicit defaults", () => {
  assert.deepEqual(parseLegacyBoardImport(legacyDocument()), {
    columns: [
      {
        title: "Pendientes",
        position: 0,
        tasks: [
          {
            title: "Revisar respaldo",
            description: null,
            priority: "high",
            position: 0,
          },
        ],
      },
    ],
  });
});

test("legacy identity and permission fields are rejected instead of trusted", () => {
  const input = legacyDocument();
  input.board.owner_id = "synthetic-foreign-owner";

  assert.throws(() => parseLegacyBoardImport(input));
});

test("legacy imports reject unsupported versions and entity-limit violations", () => {
  assert.throws(() => parseLegacyBoardImport(legacyDocument({ version: 2 })));

  const tooManyColumns = legacyDocument();
  tooManyColumns.board.columns = Array.from({ length: 51 }, (_, position) => ({
    title: `Columna ${position}`,
    position,
    tasks: [],
  }));
  assert.throws(() => parseLegacyBoardImport(tooManyColumns));

  const tooManyTasks = legacyDocument();
  tooManyTasks.board.columns[0].tasks = Array.from(
    { length: 501 },
    (_, position) => ({
      title: `Tarea ${position}`,
      description: null,
      priority: "medium",
      position,
    }),
  );
  assert.throws(() => parseLegacyBoardImport(tooManyTasks));
});

test("legacy import size keeps the v1 2 MiB limit inclusive", () => {
  assert.doesNotThrow(() =>
    validateLegacyBoardImportSize(MAX_LEGACY_BOARD_IMPORT_BYTES),
  );
  assert.throws(() =>
    validateLegacyBoardImportSize(MAX_LEGACY_BOARD_IMPORT_BYTES + 1),
  );
});
