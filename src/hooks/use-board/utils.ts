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
  toast.error(`Failed to ${action}`, {
    description: "Your changes have been reverted. Please try again.",
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
