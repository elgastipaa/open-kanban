"use client";

import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useId,
  useLayoutEffect,
  useMemo,
  useState,
} from "react";
import { saveAccountThemePreference } from "@/lib/theme-preference-actions";
import {
  beginThemePreferenceChange,
  createThemePreferenceState,
  resolveThemePreferenceConflict,
  settleThemePreferenceSave,
  type ThemePreference,
  type ThemePreferenceSaveResult,
  type ThemePreferenceSnapshot,
  type ThemePreferenceState,
} from "@/lib/theme-preference-state";

interface ThemePreferenceContextValue {
  state: ThemePreferenceState;
  changeTheme: (theme: ThemePreference) => void;
  retrySave: () => void;
  loadSavedTheme: () => void;
  keepLocalTheme: () => void;
  resetTheme: () => void;
}

const ThemePreferenceContext =
  createContext<ThemePreferenceContextValue | null>(null);

interface ThemePreferenceProviderProps {
  accountId: string | null;
  initialPreference: ThemePreferenceSnapshot;
  loadFailed?: boolean;
  children: ReactNode;
}

export function ThemePreferenceProvider({
  accountId,
  initialPreference,
  loadFailed = false,
  children,
}: ThemePreferenceProviderProps) {
  const [state, setState] = useState(() =>
    createThemePreferenceState(accountId, initialPreference, loadFailed),
  );

  useLayoutEffect(() => {
    if (state.accountId !== accountId) {
      setState(
        createThemePreferenceState(accountId, initialPreference, loadFailed),
      );
    }
  }, [accountId, initialPreference, loadFailed, state.accountId]);

  useLayoutEffect(() => {
    document.documentElement.dataset.theme = state.theme;
  }, [state.theme]);

  const persist = useCallback(
    async (
      theme: ThemePreference,
      expectedVersion: number,
      requestAccountId: string | null,
    ) => {
      if (!requestAccountId) return;

      let result: ThemePreferenceSaveResult;
      try {
        result = await saveAccountThemePreference(theme, expectedVersion);
      } catch {
        result = { status: "error" } as const;
      }
      setState((current) =>
        current.accountId === requestAccountId
          ? settleThemePreferenceSave(current, result)
          : current,
      );
    },
    [],
  );

  const changeTheme = useCallback(
    (theme: ThemePreference) => {
      const nextState = beginThemePreferenceChange(state, theme);
      if (nextState === state) return;
      setState(nextState);
      void persist(theme, state.version, state.accountId);
    },
    [persist, state],
  );

  const retrySave = useCallback(() => {
    if (!state.error || state.isSaving || state.conflict || !state.accountId) {
      return;
    }
    setState({ ...state, isSaving: true, error: null });
    void persist(state.theme, state.version, state.accountId);
  }, [persist, state]);

  const loadSavedTheme = useCallback(() => {
    setState((current) => {
      const next = resolveThemePreferenceConflict(current, "load-saved");
      return "state" in next ? next.state : next;
    });
  }, []);

  const keepLocalTheme = useCallback(() => {
    const resolution = resolveThemePreferenceConflict(state, "keep-local");
    if ("command" in resolution) {
      setState(resolution.state);
      void persist(
        resolution.command.theme,
        resolution.command.expectedVersion,
        state.accountId,
      );
      return;
    }
    setState(resolution);
  }, [persist, state]);

  const resetTheme = useCallback(() => {
    setState(createThemePreferenceState(null));
  }, []);

  const value = useMemo(
    () => ({
      state,
      changeTheme,
      retrySave,
      loadSavedTheme,
      keepLocalTheme,
      resetTheme,
    }),
    [state, changeTheme, retrySave, loadSavedTheme, keepLocalTheme, resetTheme],
  );

  return (
    <ThemePreferenceContext.Provider value={value}>
      {children}
    </ThemePreferenceContext.Provider>
  );
}

export function useThemePreference(): ThemePreferenceContextValue {
  const context = useContext(ThemePreferenceContext);
  if (!context) {
    throw new Error("ThemePreferenceProvider is required.");
  }
  return context;
}

export function ThemePreferenceControl({
  compact = false,
}: {
  compact?: boolean;
}) {
  const id = useId();
  const { state, changeTheme, retrySave, loadSavedTheme, keepLocalTheme } =
    useThemePreference();
  const messageId = `${id}-message`;

  if (!state.accountId) return null;

  return (
    <div className={compact ? "w-28 shrink-0" : "min-w-32"}>
      <label
        htmlFor={id}
        className={
          compact
            ? "sr-only"
            : "mb-1 block font-medium text-text-secondary text-xs"
        }
      >
        Tema
      </label>
      <select
        id={id}
        value={state.theme}
        onChange={(event) => changeTheme(event.target.value as ThemePreference)}
        disabled={state.isSaving || Boolean(state.conflict)}
        aria-label={compact ? "Tema" : undefined}
        aria-describedby={
          state.error || state.conflict || state.loadFailed
            ? messageId
            : undefined
        }
        className="h-9 w-full rounded-lg border border-border bg-surface-raised px-2 text-sm text-text-primary outline-none focus-visible:ring-2 focus-visible:ring-accent disabled:cursor-wait disabled:opacity-70"
      >
        <option value="system">Sistema</option>
        <option value="light">Claro</option>
        <option value="dark">Oscuro</option>
      </select>

      {state.isSaving ? (
        <output
          id={messageId}
          className="mt-2 block text-text-secondary text-xs"
          aria-live="polite"
        >
          Guardando tema…
        </output>
      ) : null}

      {state.loadFailed ? (
        <p
          id={messageId}
          className="mt-2 max-w-64 text-priority-medium text-xs"
          role="alert"
        >
          No se pudo cargar el tema guardado. Se usa Sistema en este
          dispositivo.
        </p>
      ) : null}

      {state.error ? (
        <div id={messageId} className="mt-2 max-w-72" role="alert">
          <p className="text-priority-urgent text-xs">{state.error}</p>
          <button
            type="button"
            onClick={retrySave}
            className="mt-1 rounded text-text-primary text-xs underline underline-offset-2 focus-visible:outline"
          >
            Reintentar
          </button>
        </div>
      ) : null}

      {state.conflict ? (
        <div
          id={messageId}
          className="mt-2 max-w-80 rounded-lg border border-priority-medium/40 bg-priority-medium/10 p-3"
          role="alert"
        >
          <p className="text-text-primary text-xs">
            El tema guardado cambió en otro dispositivo. Tu elección local sigue
            activa; la cuenta guarda «{themeLabel(state.conflict.theme)}».
          </p>
          <div className="mt-2 flex flex-wrap gap-2">
            <button
              type="button"
              onClick={loadSavedTheme}
              className="rounded border border-border px-2 py-1 text-text-primary text-xs focus-visible:outline"
            >
              Cargar la guardada
            </button>
            <button
              type="button"
              onClick={keepLocalTheme}
              className="rounded bg-accent px-2 py-1 font-medium text-accent-foreground text-xs focus-visible:outline"
            >
              Revisar y conservar la local
            </button>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function themeLabel(theme: ThemePreference): string {
  if (theme === "light") return "Claro";
  if (theme === "dark") return "Oscuro";
  return "Sistema";
}
