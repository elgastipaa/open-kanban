"use client";

import type {
  ViewPreferenceSnapshot,
  ViewPreferenceState,
  ViewPreferenceValue,
} from "@/lib/view-preference-state";

const labels: Record<string, string> = {
  completed_view: "visibilidad de completadas",
  filter_board: "filtro de tablero",
  filter_due: "filtro de fecha",
  filter_labels: "filtros de etiquetas",
  filter_priority: "filtro de prioridad",
  filter_responsibility: "filtro de responsable",
  include_completed: "visibilidad de completadas",
  include_history: "historial de repeticiones",
  labels: "filtros de etiquetas",
  order: "orden",
};

export function ViewPreferenceStatus({
  state,
  loadFailed,
  onRetry,
  onRetryLoad,
  onResolveConflict,
  onClearReference,
  resetConflict,
  resetFailed,
  onResolveResetConflict,
  onRetryReset,
}: {
  state: ViewPreferenceState;
  loadFailed?: boolean;
  onRetry?: (preferenceKey: string) => void;
  onRetryLoad?: () => void;
  onResolveConflict?: (
    preferenceKey: string,
    resolution: "load-saved" | "keep-local",
  ) => void;
  onClearReference?: (preferenceKey: string) => void;
  resetConflict?: ViewPreferenceSnapshot | null;
  resetFailed?: boolean;
  onResolveResetConflict?: (
    resolution: "load-current" | "confirm-reset",
  ) => void;
  onRetryReset?: () => void;
}) {
  const savingKeys = Object.keys(state.saving);
  const conflictKeys = Object.keys(state.conflicts);
  const errorKeys = Object.keys(state.errors);
  if (
    !loadFailed &&
    !savingKeys.length &&
    !conflictKeys.length &&
    !errorKeys.length &&
    !resetConflict &&
    !resetFailed
  ) {
    return null;
  }

  return (
    <aside
      className="rounded-xl border border-priority-medium/30 bg-priority-medium/10 p-3 text-sm"
      aria-label="Estado de preferencias de esta vista"
    >
      {loadFailed ? (
        <div role="alert">
          <p>
            No se pudieron cargar las preferencias de esta vista. Tus cambios
            locales siguen disponibles.
          </p>
          {onRetryLoad ? (
            <button
              type="button"
              onClick={onRetryLoad}
              className="mt-2 rounded underline underline-offset-2 focus-visible:outline"
            >
              Reintentar carga
            </button>
          ) : null}
        </div>
      ) : null}
      {resetConflict ? (
        <div role="alert" className="mt-2">
          <p>
            Cambió la configuración guardada de este contexto. No se reinició
            nada. Versión actual:
          </p>
          <ul className="mt-1 list-disc pl-5">
            {Object.entries(resetConflict.preferences ?? {}).map(
              ([key, preference]) => (
                <li key={key}>
                  {preferenceLabel(key)}: {describe(preference.value)}
                </li>
              ),
            )}
          </ul>
          <div className="mt-2 flex flex-wrap gap-2">
            <button
              type="button"
              onClick={() => onResolveResetConflict?.("load-current")}
              className="rounded border border-border px-2 py-1 text-xs focus-visible:outline"
            >
              Cargar la configuración actual
            </button>
            <button
              type="button"
              onClick={() => onResolveResetConflict?.("confirm-reset")}
              className="rounded bg-accent px-2 py-1 text-accent-foreground text-xs focus-visible:outline"
            >
              Reiniciar con esta versión actual
            </button>
          </div>
        </div>
      ) : null}
      {resetFailed ? (
        <div role="alert" className="mt-2">
          <p>No se pudieron reiniciar las preferencias de este contexto.</p>
          {onRetryReset ? (
            <button
              type="button"
              onClick={onRetryReset}
              className="mt-2 rounded underline underline-offset-2 focus-visible:outline"
            >
              Reintentar reinicio
            </button>
          ) : null}
        </div>
      ) : null}
      {savingKeys.length ? (
        <output aria-live="polite">
          Guardando preferencias de esta vista…
        </output>
      ) : null}
      {conflictKeys.map((key) => (
        <div key={key} role="alert" className="mt-2">
          <p>
            Cambió {preferenceLabel(key)} en otro dispositivo. Tu elección local
            sigue activa ({describe(state.values[key])}) y la guardada es{" "}
            {describe(state.conflicts[key].value)}.
          </p>
          <div className="mt-2 flex flex-wrap gap-2">
            <button
              type="button"
              onClick={() => onResolveConflict?.(key, "load-saved")}
              className="rounded border border-border px-2 py-1 text-xs focus-visible:outline"
            >
              Cargar la guardada
            </button>
            <button
              type="button"
              onClick={() => onResolveConflict?.(key, "keep-local")}
              className="rounded bg-accent px-2 py-1 text-accent-foreground text-xs focus-visible:outline"
            >
              Revisar y conservar la local
            </button>
          </div>
        </div>
      ))}
      {errorKeys.map((key) => (
        <div key={key} role="alert" className="mt-2">
          {state.errors[key] === "invalid_reference" ? (
            <>
              <p>
                {preferenceLabel(key)} contiene una referencia que ya no está
                disponible. Revisa o quita ese filtro para continuar.
              </p>
              {onClearReference ? (
                <button
                  type="button"
                  onClick={() => onClearReference(key)}
                  className="mt-2 rounded underline underline-offset-2 focus-visible:outline"
                >
                  Quitar este filtro
                </button>
              ) : null}
            </>
          ) : (
            <>
              <p>No se pudo guardar {preferenceLabel(key)}.</p>
              {onRetry ? (
                <button
                  type="button"
                  onClick={() => onRetry(key)}
                  className="mt-2 rounded underline underline-offset-2 focus-visible:outline"
                >
                  Reintentar
                </button>
              ) : null}
            </>
          )}
        </div>
      ))}
    </aside>
  );
}

function preferenceLabel(key: string): string {
  return labels[key] ?? "esta preferencia";
}

function describe(value: ViewPreferenceValue | undefined): string {
  if (value === undefined || value === null) return "sin filtro";
  if (typeof value === "boolean") return value ? "activado" : "desactivado";
  if (typeof value === "string") {
    if (value === "due") return "por vencimiento";
    if (value === "created") return "por creación";
    if (value === "today") return "Hoy";
    if (value === "overdue") return "Vencidas";
    if (value === "next_7_days") return "Próximos 7 días";
    if (value === "no_date") return "Sin fecha";
    return "una selección guardada";
  }
  if (Array.isArray(value)) return `${value.length} elemento(s)`;
  if ("assignee_id" in value) {
    return value.unassigned ? "Sin responsable" : "cualquier responsable";
  }
  if ("hidden" in value) {
    return `${value.hidden.length} oculta(s), ${value.collapsed.length} contraída(s)`;
  }
  if ("visible" in value) {
    return value.visible
      ? value.expanded
        ? "visible y expandida"
        : "visible y contraída"
      : "oculta";
  }
  return "una selección guardada";
}
