import assert from "node:assert/strict";
import { test } from "node:test";
import { getInvitationAcceptanceResolution } from "../../src/lib/invitation-acceptance-state.ts";

test("expired unknown acceptance prompts membership reconciliation without claiming no effect", () => {
  const resolution = getInvitationAcceptanceResolution("expired_unknown");

  assert.deepEqual(resolution, {
    message:
      "No pudimos confirmar si la aceptación se completó. Ve a Tableros y verifica si ya tienes acceso. Si no aparece, actualiza esta página para volver a consultar la invitación antes de aceptar otra vez.",
    requiresReconciliation: true,
  });
  assert.doesNotMatch(resolution.message, /no se realizó ningún cambio/i);
});

test("unavailable acceptance remains a separate generic outcome", () => {
  assert.deepEqual(getInvitationAcceptanceResolution("unavailable"), {
    message: "Esta invitación ya no está disponible.",
    requiresReconciliation: false,
  });
});
