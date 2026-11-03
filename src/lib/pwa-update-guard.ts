export type PwaUpdateGuard = (continueUpdate: () => void) => boolean;

export interface PwaUpdateGuardRegistry {
  current: PwaUpdateGuard | null;
}

export type PwaUpdateChoice = "save" | "discard" | "continue";
export type PwaUpdateSaveOutcome =
  | "confirmed"
  | "error"
  | "conflict"
  | "reconciliation";
export type PwaUpdateResolution = "activate" | "wait" | "cancel";

/** Keep the active editor's update guard in its component-local lifetime. */
export function createPwaUpdateGuardRegistry(): PwaUpdateGuardRegistry {
  return { current: null };
}

export function registerPwaUpdateGuard(
  registry: PwaUpdateGuardRegistry,
  guard: PwaUpdateGuard,
): () => void {
  registry.current = guard;
  return () => {
    if (registry.current === guard) registry.current = null;
  };
}

/** Let an open editor defer an explicit update request until it is resolved. */
export function requestPwaUpdate(
  registry: PwaUpdateGuardRegistry,
  continueUpdate: () => void,
): "activated" | "deferred" {
  if (registry.current?.(continueUpdate)) return "deferred";
  continueUpdate();
  return "activated";
}

export function resolvePwaUpdateChoice(
  choice: PwaUpdateChoice,
  saveOutcome?: PwaUpdateSaveOutcome,
): PwaUpdateResolution {
  if (choice === "discard") return "activate";
  if (choice === "continue") return "cancel";
  return saveOutcome === "confirmed" ? "activate" : "wait";
}
