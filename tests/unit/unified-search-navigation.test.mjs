import assert from "node:assert/strict";
import { test } from "node:test";
import {
  buildUnifiedSearchHref,
  buildUnifiedSearchResultHref,
  isGlobalSearchShortcut,
} from "../../src/lib/unified-search-navigation.ts";

const boardId = "33000000-0000-4000-8000-000000000001";
const taskId = "33000000-0000-4000-8000-000000000002";
const commentId = "33000000-0000-4000-8000-000000000003";
const seriesId = "33000000-0000-4000-8000-000000000004";
const occurrenceId = "33000000-0000-4000-8000-000000000005";

test("current tasks and comments open the precise board and task identity", () => {
  assert.equal(
    buildUnifiedSearchResultHref({
      kind: "task",
      board_slug: "proyecto-a",
      task_id: taskId,
    }),
    `/proyecto-a?task=${taskId}`,
  );
  assert.equal(
    buildUnifiedSearchResultHref({
      kind: "comment",
      board_slug: "proyecto-a",
      task_id: taskId,
      comment_id: commentId,
    }),
    `/proyecto-a?task=${taskId}&comment=${commentId}`,
  );
});

test("replaced occurrences open read-only history anchored to the selected comment", () => {
  assert.equal(
    buildUnifiedSearchResultHref({
      kind: "comment",
      board_id: boardId,
      task_id: taskId,
      comment_id: commentId,
      is_historical: true,
      occurrence_state: "replaced",
      series_id: seriesId,
      occurrence_id: occurrenceId,
    }),
    `/series?board=${boardId}&series=${seriesId}&occurrence=${occurrenceId}&comment=${commentId}#comment-${commentId}`,
  );
});

test("boards are navigable but label suggestions do not masquerade as destinations", () => {
  assert.equal(
    buildUnifiedSearchResultHref({ kind: "board", board_slug: "proyecto-a" }),
    "/proyecto-a",
  );
  assert.equal(
    buildUnifiedSearchResultHref({ kind: "label", board_slug: "proyecto-a" }),
    null,
  );
  assert.equal(
    buildUnifiedSearchResultHref({ kind: "board", board_slug: "../account" }),
    null,
  );
});

test("the global search button and shortcut keep the originating context", () => {
  assert.equal(
    buildUnifiedSearchHref("/my-tasks", new URLSearchParams("order=created")),
    "/search?scope=my_tasks&order=created",
  );
  assert.equal(
    buildUnifiedSearchHref("/proyecto-a", new URLSearchParams()),
    "/search?scope=board&board_slug=proyecto-a",
  );
  assert.equal(
    buildUnifiedSearchHref("/", new URLSearchParams()),
    "/search?scope=all",
  );
  assert.equal(
    buildUnifiedSearchHref(
      "/search",
      new URLSearchParams(
        "q=texto&scope=all&label=board-a%3Alabel-a&label=board-b%3Alabel-b&access_token=secret",
      ),
    ),
    "/search?q=texto&scope=all&label=board-a%3Alabel-a&label=board-b%3Alabel-b",
  );
});

test("Ctrl/Cmd+K opens search only outside writing fields", () => {
  const shortcut = {
    key: "k",
    ctrlKey: true,
    metaKey: false,
    altKey: false,
    shiftKey: false,
  };
  assert.equal(
    isGlobalSearchShortcut({ ...shortcut, targetTag: "body" }),
    true,
  );
  assert.equal(
    isGlobalSearchShortcut({ ...shortcut, targetTag: "input" }),
    false,
  );
  assert.equal(
    isGlobalSearchShortcut({ ...shortcut, targetTag: "textarea" }),
    false,
  );
  assert.equal(
    isGlobalSearchShortcut({ ...shortcut, targetRole: "textbox" }),
    false,
  );
  assert.equal(
    isGlobalSearchShortcut({ ...shortcut, targetRole: "searchbox" }),
    false,
  );
  assert.equal(
    isGlobalSearchShortcut({ ...shortcut, contentEditable: true }),
    false,
  );
  assert.equal(isGlobalSearchShortcut({ ...shortcut, shiftKey: true }), false);
  assert.equal(
    isGlobalSearchShortcut({ ...shortcut, ctrlKey: false, metaKey: false }),
    false,
  );
});
