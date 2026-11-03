import assert from "node:assert/strict";
import { test } from "node:test";
import {
  createRepetitionPattern,
  ordinalWeekdayAdjective,
  repetitionPatternSummary,
} from "../../src/lib/repetition-pattern.ts";

const selection = (overrides = {}) => ({
  frequency: "monthly",
  interval: "1",
  weekdays: [1],
  calendarMode: "day",
  dayOfMonth: "31",
  month: "2",
  ordinal: "-1",
  weekday: "1",
  ...overrides,
});

test("monthly and yearly patterns preserve the complete calendar catalog", () => {
  assert.deepEqual(
    createRepetitionPattern(selection({ interval: "2147483648" })),
    {
      frequency: "monthly",
      interval: "2147483648",
      day_of_month: 31,
    },
  );
  assert.deepEqual(
    createRepetitionPattern(
      selection({ frequency: "yearly", calendarMode: "ordinal" }),
    ),
    {
      frequency: "yearly",
      interval: "1",
      month: 2,
      ordinal: -1,
      weekday: 1,
    },
  );
  assert.deepEqual(
    createRepetitionPattern(
      selection({ calendarMode: "ordinal", ordinal: "5", weekday: "7" }),
    ),
    {
      frequency: "monthly",
      interval: "1",
      ordinal: 5,
      weekday: 7,
    },
  );
  assert.deepEqual(createRepetitionPattern(selection({ dayOfMonth: "-1" })), {
    frequency: "monthly",
    interval: "1",
    day_of_month: -1,
  });
  assert.deepEqual(
    createRepetitionPattern(
      selection({ frequency: "yearly", month: "2", dayOfMonth: "-1" }),
    ),
    {
      frequency: "yearly",
      interval: "1",
      month: 2,
      day_of_month: -1,
    },
  );
});

test("calendar intervals accept PostgreSQL bigint range without a UI cap", () => {
  assert.equal(
    createRepetitionPattern(selection({ interval: "9223372036854775807" }))
      ?.interval,
    "9223372036854775807",
  );
  assert.equal(
    createRepetitionPattern(selection({ interval: "9223372036854775808" })),
    null,
  );
  assert.equal(createRepetitionPattern(selection({ interval: "1.5" })), null);
  assert.equal(createRepetitionPattern(selection({ interval: "0" })), null);
});

test("weekly interval and weekdays retain their existing contract", () => {
  assert.deepEqual(
    createRepetitionPattern(
      selection({
        frequency: "weekly",
        interval: "2",
        weekdays: [5, 1, 5],
      }),
    ),
    { frequency: "weekly", interval: 2, weekdays: [1, 5] },
  );
  assert.equal(
    createRepetitionPattern(selection({ frequency: "weekly", weekdays: [] })),
    null,
  );
});

test("ordinal weekday labels use Spanish ordinal forms", () => {
  assert.equal(ordinalWeekdayAdjective(1), "primer");
  assert.equal(ordinalWeekdayAdjective(2), "segundo");
  assert.equal(ordinalWeekdayAdjective(3), "tercer");
  assert.equal(ordinalWeekdayAdjective(5), "quinto");
  assert.equal(ordinalWeekdayAdjective(-1), "último");
  assert.equal(ordinalWeekdayAdjective(6), null);
});

test("calendar summaries name the selected cadence and days in Spanish", () => {
  assert.equal(
    repetitionPatternSummary({
      frequency: "weekly",
      interval: 2,
      weekdays: [1, 5],
    }),
    "Cada 2 semanas · lunes, viernes",
  );
  assert.equal(
    repetitionPatternSummary({
      frequency: "monthly",
      interval: "1",
      ordinal: -1,
      weekday: 3,
    }),
    "El último miércoles de cada mes",
  );
  assert.equal(
    repetitionPatternSummary({ frequency: "daily", interval: 1 }),
    "Cada día",
  );
});
