export type TaskDueState =
  | "unscheduled"
  | "upcoming"
  | "today"
  | "overdue"
  | "completed";

export function isDateOnly(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || value.startsWith("0000")) {
    return false;
  }
  const date = new Date(`${value}T00:00:00.000Z`);
  return (
    Number.isFinite(date.valueOf()) && date.toISOString().slice(0, 10) === value
  );
}

/** Classifies a date-only deadline against the board's database-provided day. */
export function taskDueState(
  dueOn: string | null,
  boardToday: string,
  isCompleted: boolean,
): TaskDueState {
  if (!dueOn) return "unscheduled";
  if (isCompleted) return "completed";
  if (dueOn < boardToday) return "overdue";
  if (dueOn === boardToday) return "today";
  return "upcoming";
}

/** Formats a SQL DATE without interpreting midnight in the device time zone. */
export function formatTaskDueDate(dueOn: string | null): string | null {
  if (!dueOn) return null;
  const [year, month, day] = dueOn.split("-").map(Number);
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(0, 0, 0, 0);
  return new Intl.DateTimeFormat("es-AR", {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  })
    .format(date)
    .replaceAll(".", "");
}

export function taskDueDateLabel(
  dueOn: string | null,
  boardToday: string,
  isCompleted: boolean,
): string | null {
  const formattedDate = formatTaskDueDate(dueOn);
  if (!formattedDate) return null;
  switch (taskDueState(dueOn, boardToday, isCompleted)) {
    case "today":
      return "Vence hoy";
    case "overdue":
      return `Vencida · ${formattedDate}`;
    case "upcoming":
      return `Vence ${formattedDate}`;
    case "completed":
      return `Fecha límite: ${formattedDate}`;
    case "unscheduled":
      return null;
  }
}
