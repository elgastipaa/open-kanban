import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  ThemePreference,
  ThemePreferenceSaveResult,
  ThemePreferenceSnapshot,
} from "@/lib/theme-preference-state";

export class ThemePreferenceError extends Error {
  readonly reason: "access_denied" | "uncertain";

  constructor(reason: "access_denied" | "uncertain") {
    super("No se pudo confirmar el tema de la cuenta.");
    this.name = "ThemePreferenceError";
    this.reason = reason;
  }
}

function isThemePreference(value: unknown): value is ThemePreference {
  return value === "system" || value === "light" || value === "dark";
}

function isVersion(value: unknown): value is number {
  return Number.isInteger(value) && typeof value === "number" && value >= 0;
}

function preferenceError(error: { code?: string }): ThemePreferenceError {
  return new ThemePreferenceError(
    error.code === "42501" ? "access_denied" : "uncertain",
  );
}

export async function getMyThemePreference(
  supabase: SupabaseClient,
): Promise<ThemePreferenceSnapshot> {
  const { data, error } = await supabase.rpc("get_my_theme_preference_p");
  if (error) throw preferenceError(error);

  const row = Array.isArray(data) ? data[0] : null;
  if (
    typeof row !== "object" ||
    row === null ||
    !("theme" in row) ||
    !isThemePreference(row.theme) ||
    !("version" in row) ||
    !isVersion(row.version)
  ) {
    throw new ThemePreferenceError("uncertain");
  }

  return { theme: row.theme, version: row.version };
}

export async function saveMyThemePreference(
  supabase: SupabaseClient,
  theme: ThemePreference,
  expectedVersion: number,
): Promise<ThemePreferenceSaveResult> {
  const { data, error } = await supabase.rpc("set_my_theme_preference_p", {
    p_theme: theme,
    p_expected_version: expectedVersion,
  });
  if (error) throw preferenceError(error);

  if (typeof data !== "object" || data === null) {
    throw new ThemePreferenceError("uncertain");
  }

  if (
    !("status" in data) ||
    !("theme" in data) ||
    !isThemePreference(data.theme) ||
    !("version" in data) ||
    !isVersion(data.version)
  ) {
    throw new ThemePreferenceError("uncertain");
  }

  if (data.status === "saved" || data.status === "conflict") {
    return {
      status: data.status,
      theme: data.theme,
      version: data.version,
    };
  }

  throw new ThemePreferenceError("uncertain");
}
