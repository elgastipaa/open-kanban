import assert from "node:assert/strict";
import { test } from "node:test";
import {
  formatTaskDueDate,
  isDateOnly,
  taskDueState,
} from "../../src/lib/task-date.ts";

test("a punctual due date is classified against the board day", () => {
  assert.equal(taskDueState(null, "2026-10-31", false), "unscheduled");
  assert.equal(taskDueState("2026-10-31", "2026-10-31", false), "today");
  assert.equal(taskDueState("2026-10-30", "2026-10-31", false), "overdue");
  assert.equal(taskDueState("2026-11-01", "2026-10-31", false), "upcoming");
  assert.equal(taskDueState("2026-10-30", "2026-10-31", true), "completed");
});

test("a date-only value formats without moving to the device day", () => {
  assert.equal(formatTaskDueDate("2026-10-31"), "31 de oct de 2026");
  assert.equal(formatTaskDueDate("0001-02-03"), "3 de feb de 1");
  assert.equal(formatTaskDueDate(null), null);
});

test("only finite valid YYYY-MM-DD values can be scheduled", () => {
  assert.equal(isDateOnly("2026-02-28"), true);
  assert.equal(isDateOnly("0001-02-03"), true);
  assert.equal(isDateOnly("2026-02-30"), false);
  assert.equal(isDateOnly("infinity"), false);
  assert.equal(isDateOnly("2026-2-3"), false);
});

test("changing board days changes the label without rewriting the deadline", () => {
  const dueOn = "2026-10-31";
  assert.equal(taskDueState(dueOn, "2026-10-31", false), "today");
  assert.equal(taskDueState(dueOn, "2026-11-01", false), "overdue");
  assert.equal(taskDueState(dueOn, "2026-10-31", false), "today");
  assert.equal(dueOn, "2026-10-31");
});

test("one controlled instant yields different due states in two IANA zones", () => {
  const boardDayAt = (instant, timeZone) => {
    const parts = Object.fromEntries(
      new Intl.DateTimeFormat("en-US", {
        timeZone,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
      })
        .formatToParts(instant)
        .map(({ type, value }) => [type, value]),
    );
    return `${parts.year}-${parts.month}-${parts.day}`;
  };
  const controlledInstant = new Date("2026-11-01T01:00:00.000Z");
  const dueOn = "2026-10-31";
  const losAngelesToday = boardDayAt(controlledInstant, "America/Los_Angeles");
  const parisToday = boardDayAt(controlledInstant, "Europe/Paris");

  assert.equal(losAngelesToday, "2026-10-31");
  assert.equal(parisToday, "2026-11-01");
  assert.equal(taskDueState(dueOn, losAngelesToday, false), "today");
  assert.equal(taskDueState(dueOn, parisToday, false), "overdue");
  assert.equal(taskDueState(dueOn, losAngelesToday, false), "today");
  assert.equal(dueOn, "2026-10-31");
});
