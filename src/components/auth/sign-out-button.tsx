"use client";

import { useThemePreference } from "@/components/theme/theme-preference-provider";
import { signOut } from "@/lib/auth-actions";

export function SignOutButton() {
  const { resetTheme } = useThemePreference();

  return (
    <form action={signOut} onSubmit={resetTheme}>
      <button
        type="submit"
        className="rounded-lg border border-border px-4 py-2 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary"
      >
        Cerrar sesión
      </button>
    </form>
  );
}
