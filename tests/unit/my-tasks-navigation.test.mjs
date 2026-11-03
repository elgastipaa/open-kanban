import assert from "node:assert/strict";
import { test } from "node:test";
import {
  myTaskBoardHref,
  myTasksHref,
} from "../../src/lib/my-tasks-navigation.ts";

test("opening a personal task carries its source identity and order context", () => {
  const taskId = "30000000-0000-4000-8000-000000000013";
  assert.equal(
    myTaskBoardHref("board-a", taskId, "created"),
    `/board-a?task=${taskId}&from=my-tasks&order=created`,
  );
  assert.equal(myTasksHref("created"), "/my-tasks?order=created");
});

test("a personal task destination keeps its source board and task identity", () => {
  assert.equal(
    myTaskBoardHref("board-b", "task-17", "due"),
    "/board-b?task=task-17&from=my-tasks&order=due",
  );
});
