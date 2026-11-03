export type MyTaskCompletionControl =
  | {
      kind: "status";
      label: "Completada";
      accessibleLabel: string;
    }
  | {
      kind: "action";
      label: "Completar";
      accessibleLabel: string;
    };

export function getMyTaskCompletionControl(
  isCompleted: boolean,
  taskTitle: string,
): MyTaskCompletionControl {
  return isCompleted
    ? {
        kind: "status",
        label: "Completada",
        accessibleLabel: `Tarea completada: ${taskTitle}`,
      }
    : {
        kind: "action",
        label: "Completar",
        accessibleLabel: `Completar tarea: ${taskTitle}`,
      };
}
