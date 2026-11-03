export type ThemePreference = "system" | "light" | "dark";

export interface ThemePreferenceSnapshot {
  theme: ThemePreference;
  version: number;
}

export interface ThemePreferenceConflict {
  theme: ThemePreference;
  version: number;
}

export interface ThemePreferenceState {
  accountId: string | null;
  theme: ThemePreference;
  version: number;
  isSaving: boolean;
  error: string | null;
  conflict: ThemePreferenceConflict | null;
  loadFailed: boolean;
}

export type ThemePreferenceSaveResult =
  | { status: "saved"; theme: ThemePreference; version: number }
  | { status: "conflict"; theme: ThemePreference; version: number }
  | { status: "error" };

export function createThemePreferenceState(
  accountId: string | null,
  snapshot: ThemePreferenceSnapshot = { theme: "system", version: 0 },
  loadFailed = false,
): ThemePreferenceState {
  return {
    accountId,
    theme: snapshot.theme,
    version: snapshot.version,
    isSaving: false,
    error: null,
    conflict: null,
    loadFailed,
  };
}

export function beginThemePreferenceChange(
  state: ThemePreferenceState,
  theme: ThemePreference,
): ThemePreferenceState {
  if (
    !state.accountId ||
    state.isSaving ||
    state.conflict ||
    state.theme === theme
  ) {
    return state;
  }

  return {
    ...state,
    theme,
    isSaving: true,
    error: null,
    loadFailed: false,
  };
}

export function settleThemePreferenceSave(
  state: ThemePreferenceState,
  result: ThemePreferenceSaveResult,
): ThemePreferenceState {
  if (result.status === "saved") {
    return {
      ...state,
      theme: result.theme,
      version: result.version,
      isSaving: false,
      error: null,
      conflict: null,
      loadFailed: false,
    };
  }

  if (result.status === "conflict") {
    if (result.theme === state.theme) {
      return {
        ...state,
        version: result.version,
        isSaving: false,
        error: null,
        conflict: null,
        loadFailed: false,
      };
    }

    return {
      ...state,
      isSaving: false,
      error: null,
      conflict: { theme: result.theme, version: result.version },
      loadFailed: false,
    };
  }

  return {
    ...state,
    isSaving: false,
    error: "No se pudo sincronizar el tema. Inténtalo de nuevo.",
  };
}

export function resolveThemePreferenceConflict(
  state: ThemePreferenceState,
  resolution: "load-saved" | "keep-local",
):
  | ThemePreferenceState
  | {
      state: ThemePreferenceState;
      command: { theme: ThemePreference; expectedVersion: number };
    } {
  if (!state.conflict) return state;

  if (resolution === "load-saved") {
    return {
      ...state,
      theme: state.conflict.theme,
      version: state.conflict.version,
      error: null,
      conflict: null,
      loadFailed: false,
    };
  }

  const expectedVersion = state.conflict.version;
  return {
    state: {
      ...state,
      version: expectedVersion,
      isSaving: true,
      error: null,
      conflict: null,
      loadFailed: false,
    },
    command: { theme: state.theme, expectedVersion },
  };
}
