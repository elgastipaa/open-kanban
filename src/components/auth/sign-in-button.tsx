"use client";

import { IconBrandGoogle } from "@tabler/icons-react";
import { useState } from "react";
import { createClient } from "@/lib/supabase/client";

export function SignInButton({ nextPath = "/" }: { nextPath?: string }) {
  const [isLoading, setIsLoading] = useState(false);
  const [hasError, setHasError] = useState(false);

  async function signIn() {
    setIsLoading(true);
    setHasError(false);
    const callback = new URL("/auth/callback", window.location.origin);
    callback.searchParams.set("next", nextPath);

    const { error } = await createClient().auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo: callback.toString() },
    });

    if (error) {
      setIsLoading(false);
      setHasError(true);
    }
  }

  return (
    <div className="w-full">
      <button
        type="button"
        onClick={signIn}
        disabled={isLoading}
        className="flex min-h-12 w-full items-center justify-center gap-3 rounded-xl bg-white px-5 py-3 font-semibold text-neutral-950 transition hover:bg-neutral-200 disabled:cursor-wait disabled:opacity-70"
      >
        <IconBrandGoogle size={20} aria-hidden="true" />
        {isLoading ? "Conectando…" : "Entrar con Google"}
      </button>
      {hasError ? (
        <p className="mt-3 text-center text-red-300 text-sm" role="alert">
          No se pudo iniciar sesión. Inténtalo de nuevo.
        </p>
      ) : null}
    </div>
  );
}
