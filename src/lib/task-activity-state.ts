import type { TaskActivityActorType, TaskActivityCategory } from "./types";

export function taskActivityActorLabel(
  actorType: TaskActivityActorType,
  actorName: string | null,
): string {
  if (actorType === "system") return "Sistema";
  if (actorType === "imported") {
    return actorName
      ? `Actividad importada · ${actorName}`
      : "Actividad importada";
  }
  return actorName ?? "Miembro del tablero";
}

function displayDate(value: string | boolean | null): string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/u.test(value)) {
    return "Sin fecha";
  }
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(0, 0, 0, 0);
  if (date.toISOString().slice(0, 10) !== value) return "Sin fecha";
  return new Intl.DateTimeFormat("es-AR", {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  })
    .format(date)
    .replaceAll(".", "");
}

function displayValue(
  category: TaskActivityCategory,
  value: string | boolean | null,
): string {
  if (category === "due_date") return displayDate(value);
  if (category === "completion") {
    return value === true ? "Completada" : "Pendiente";
  }
  return typeof value === "string" ? value : "Sin valor";
}

export function describeTaskActivityEvent(event: {
  category: TaskActivityCategory;
  before_value: string | boolean | null;
  after_value: string | boolean | null;
}): { label: string; value: string } {
  switch (event.category) {
    case "assignee":
      return {
        label: "Responsable",
        value: `${displayValue(event.category, event.before_value)} → ${displayValue(event.category, event.after_value)}`,
      };
    case "due_date":
      return {
        label: "Fecha límite",
        value: `${displayValue(event.category, event.before_value)} → ${displayValue(event.category, event.after_value)}`,
      };
    case "column":
      return {
        label: "Columna",
        value: `${displayValue(event.category, event.before_value)} → ${displayValue(event.category, event.after_value)}`,
      };
    case "completion":
      return {
        label: "Estado",
        value: `${displayValue(event.category, event.before_value)} → ${displayValue(event.category, event.after_value)}`,
      };
    case "recovery":
      return { label: "Recuperación", value: "Tarea recuperada" };
  }
}
