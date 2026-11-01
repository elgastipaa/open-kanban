import assert from "node:assert/strict";
import test from "node:test";
import {
  boardFavoriteFailureMessage,
  groupFavoriteBoards,
  updateFavoriteIds,
  updatePendingFavoriteIds,
} from "../../src/lib/board-favorites-state.ts";
import { BoardFavoriteError } from "../../src/lib/db/board-favorites.ts";

test("favorites use only boards in the currently authorized list", () => {
  const groups = groupFavoriteBoards(
    [
      { id: "board-a", name: "Trabajo personal" },
      { id: "board-b", name: "Equipo" },
    ],
    new Set(["board-a", "revoked-board"]),
  );

  assert.deepEqual(
    groups.favorites.map((board) => board.name),
    ["Trabajo personal"],
  );
  assert.deepEqual(
    groups.others.map((board) => board.name),
    ["Equipo"],
  );
});

test("a desired favorite state can be applied repeatedly without inversion", () => {
  const current = new Set(["board-a"]);
  const setFavorite = updateFavoriteIds(current, "board-b", true);
  const retry = updateFavoriteIds(setFavorite, "board-b", true);
  const remove = updateFavoriteIds(retry, "board-b", false);

  assert.deepEqual([...current], ["board-a"]);
  assert.deepEqual([...setFavorite].sort(), ["board-a", "board-b"]);
  assert.deepEqual([...retry].sort(), ["board-a", "board-b"]);
  assert.deepEqual([...remove], ["board-a"]);
});

test("one pending favorite blocks only the same board and preserves other operations", () => {
  const first = updatePendingFavoriteIds(new Set(), "board-a", true);
  const both = updatePendingFavoriteIds(first, "board-b", true);
  const afterFirstCompletes = updatePendingFavoriteIds(both, "board-a", false);

  assert.deepEqual([...first], ["board-a"]);
  assert.deepEqual([...both].sort(), ["board-a", "board-b"]);
  assert.deepEqual([...afterFirstCompletes], ["board-b"]);
  assert.deepEqual([...first], ["board-a"]);
});

test("favorite failures stay clear and do not reveal revoked board names", () => {
  const accessDenied = boardFavoriteFailureMessage(
    new BoardFavoriteError("access_denied"),
  );
  const uncertain = boardFavoriteFailureMessage(
    new BoardFavoriteError("uncertain"),
  );

  assert.equal(
    accessDenied,
    "No se pudo confirmar el acceso. Actualiza la lista para continuar.",
  );
  assert.equal(
    uncertain,
    "No se pudo guardar el favorito. Inténtalo de nuevo.",
  );
  assert.doesNotMatch(accessDenied, /Tablero confidencial/);
});
