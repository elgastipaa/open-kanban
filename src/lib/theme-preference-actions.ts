"use server";

import { saveMyThemePreference } from "@/lib/db/theme-preferences";
import { createClient } from "@/lib/supabase/server";
import type {
  ThemePreference,
  ThemePreferenceSaveResult,
} from "@/lib/theme-preference-state";

function isThemePreference(value: unknown): value is ThemePreference {
  return value === "system" || value === "light" || value === "dark";
}

export async function saveAccountThemePreference(
  theme: ThemePreference,
  expectedVersion: number,
): Promise<ThemePreferenceSaveResult> {
  if (
    !isThemePreference(theme) ||
    !Number.isInteger(expectedVersion) ||
    expectedVersion < 0
  ) {
    return { status: "error" };
  }

  try {
    const supabase = await createClient();
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) return { status: "error" };

    return await saveMyThemePreference(supabase, theme, expectedVersion);
  } catch {
    return { status: "error" };
  }
}
