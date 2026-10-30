"use client";

import { signOut } from "@/lib/auth-actions";

export function BoardSignOutButton() {
  return (
    <form action={signOut}>
      <button
        type="submit"
        className="rounded-lg border border-border px-3 py-2 text-sm text-text-secondary transition hover:bg-surface-overlay hover:text-text-primary"
      >
        Cerrar sesión
      </button>
    </form>
  );
}
