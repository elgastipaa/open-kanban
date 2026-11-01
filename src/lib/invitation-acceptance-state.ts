export type InvitationAcceptanceFailureStatus =
  | "unavailable"
  | "expired_unknown";

export interface InvitationAcceptanceResolution {
  message: string;
  requiresReconciliation: boolean;
}

export function getInvitationAcceptanceResolution(
  status: InvitationAcceptanceFailureStatus,
): InvitationAcceptanceResolution {
  if (status === "expired_unknown") {
    return {
      message:
        "No pudimos confirmar si la aceptación se completó. Ve a Tableros y verifica si ya tienes acceso. Si no aparece, actualiza esta página para volver a consultar la invitación antes de aceptar otra vez.",
      requiresReconciliation: true,
    };
  }

  return {
    message: "Esta invitación ya no está disponible.",
    requiresReconciliation: false,
  };
}
