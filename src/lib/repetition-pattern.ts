import type { RepetitionPattern } from "./db/daily-repetition";

export interface RepetitionPatternSelection {
  frequency: RepetitionPattern["frequency"];
  interval: string;
  weekdays: number[];
  calendarMode: "day" | "ordinal";
  dayOfMonth: string;
  month: string;
  ordinal: string;
  weekday: string;
}

const MAX_POSTGRES_BIGINT = BigInt("9223372036854775807");

function calendarInterval(value: string): string | null {
  if (!/^[0-9]+$/.test(value)) return null;
  const parsed = BigInt(value);
  if (parsed < BigInt(1) || parsed > MAX_POSTGRES_BIGINT) return null;
  return parsed.toString();
}

function selectedInteger(value: string, minimum: number, maximum: number) {
  if (!/^-?[0-9]+$/.test(value)) return null;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= minimum && parsed <= maximum
    ? parsed
    : null;
}

export function ordinalWeekdayAdjective(ordinal: number): string | null {
  switch (ordinal) {
    case 1:
      return "primer";
    case 2:
      return "segundo";
    case 3:
      return "tercer";
    case 4:
      return "cuarto";
    case 5:
      return "quinto";
    case -1:
      return "último";
    default:
      return null;
  }
}

export function createRepetitionPattern(
  selection: RepetitionPatternSelection,
): RepetitionPattern | null {
  if (selection.frequency === "daily") {
    return { frequency: "daily", interval: 1 };
  }
  if (selection.frequency === "weekly") {
    const interval = selectedInteger(selection.interval, 1, 2147483647);
    const weekdays = [...new Set(selection.weekdays)].sort(
      (left, right) => left - right,
    );
    if (
      interval === null ||
      weekdays.length === 0 ||
      weekdays.some(
        (weekday) => !Number.isInteger(weekday) || weekday < 1 || weekday > 7,
      )
    ) {
      return null;
    }
    return { frequency: "weekly", interval, weekdays };
  }

  const interval = calendarInterval(selection.interval);
  if (interval === null) return null;
  if (selection.frequency === "yearly") {
    const month = selectedInteger(selection.month, 1, 12);
    if (month === null) return null;
    if (selection.calendarMode === "day") {
      const dayOfMonth = selectedInteger(selection.dayOfMonth, -1, 31);
      return dayOfMonth === null || dayOfMonth === 0
        ? null
        : { frequency: "yearly", interval, month, day_of_month: dayOfMonth };
    }
    const ordinal = selectedInteger(selection.ordinal, -1, 5);
    const weekday = selectedInteger(selection.weekday, 1, 7);
    return ordinal === null || ordinal === 0 || weekday === null
      ? null
      : { frequency: "yearly", interval, month, ordinal, weekday };
  }

  if (selection.calendarMode === "day") {
    const dayOfMonth = selectedInteger(selection.dayOfMonth, -1, 31);
    return dayOfMonth === null || dayOfMonth === 0
      ? null
      : { frequency: "monthly", interval, day_of_month: dayOfMonth };
  }
  const ordinal = selectedInteger(selection.ordinal, -1, 5);
  const weekday = selectedInteger(selection.weekday, 1, 7);
  return ordinal === null || ordinal === 0 || weekday === null
    ? null
    : { frequency: "monthly", interval, ordinal, weekday };
}
