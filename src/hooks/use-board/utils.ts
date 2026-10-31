import { toast } from "sonner";
import type { ColumnWithTasks } from "@/lib/types";
import { generateUUID } from "@/lib/utils";

/** Create a local-only column (not yet persisted to DB) */
export function makeLocalColumn(
  title: string,
  position: number,
  id?: string,
): ColumnWithTasks {
  return {
    id: id || `local-${generateUUID()}`,
    board_id: "",
    title,
    position,
    is_collapsed: false,
    created_at: new Date().toISOString(),
    tasks: [],
  };
}

/** Show a standardized error toast for failed mutations */
export function showMutationError(action: string) {
  const actionLabels: Record<string, string> = {
    "add column": "crear la columna",
    "rename column": "renombrar la columna",
    "toggle column": "cambiar el estado de la columna",
    "toggle all columns collapse": "contraer todas las columnas",
    "toggle all columns expand": "expandir todas las columnas",
    "delete column": "eliminar la columna",
    "reorder columns": "reordenar las columnas",
    "move column": "mover la columna",
    "delete board": "eliminar el tablero",
    "delete task": "eliminar la tarea",
    "add task": "crear la tarea",
    "update task": "actualizar la tarea",
    "move task": "mover la tarea",
  };

  toast.error(`No se pudo ${actionLabels[action] ?? "guardar los cambios"}`, {
    description: "Los cambios se revirtieron. Inténtalo de nuevo.",
  });
}

export function showTaskVerificationError(onVerify: () => void) {
  toast.error("No pudimos verificar la tarea", {
    description:
      "Puede que ya esté guardada. Verifica su estado antes de crearla de nuevo.",
    action: { label: "Volver a verificar", onClick: onVerify },
    duration: 30_000,
  });
}
