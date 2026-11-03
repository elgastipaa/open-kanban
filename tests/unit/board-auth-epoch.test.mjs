import assert from "node:assert/strict";
import { test } from "node:test";
import {
  hasBoardAuthorizationEpochChanged,
  isBoardSnapshotForCurrentEpoch,
  isBoardSnapshotForCurrentSession,
} from "../../src/lib/board-auth-epoch.ts";

test("an old authorization epoch response is discarded after rotation", () => {
  assert.equal(isBoardSnapshotForCurrentEpoch("8", 7), false);
  assert.equal(isBoardSnapshotForCurrentEpoch(8, "8"), true);
  assert.equal(isBoardSnapshotForCurrentEpoch(8, undefined), false);
});

test("the board cache is invalidated only when the authorization epoch changes", () => {
  assert.equal(hasBoardAuthorizationEpochChanged(null, 1), false);
  assert.equal(hasBoardAuthorizationEpochChanged("1", 1), false);
  assert.equal(hasBoardAuthorizationEpochChanged(1, 2), true);
});

test("a board response from the previous account session is discarded", () => {
  assert.equal(isBoardSnapshotForCurrentSession(4, 5, "8", 8, 8), false);
  assert.equal(isBoardSnapshotForCurrentSession(5, 5, "8", "8", 8), true);
  assert.equal(isBoardSnapshotForCurrentSession(5, 5, "8", "9", 8), false);
  assert.equal(isBoardSnapshotForCurrentSession(5, 5, 8, 8, 7), false);
});
