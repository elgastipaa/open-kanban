import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { SignOutButton } from "@/components/auth/sign-out-button";
import { ThemePreferenceControl } from "@/components/theme/theme-preference-provider";
import { resolveApplicationAccess } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "Cuenta",
  robots: { index: false, follow: false, nocache: true },
};

export default async function AccountPage() {
  const supabase = await createClient();
  const { data: authData } = await supabase.auth.getUser();
  if (!authData.user) {
    redirect(`/login?next=${encodeURIComponent("/account")}`);
  }

  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active") redirect("/");

  return (
    <main className="mx-auto min-h-dvh max-w-3xl bg-surface-base px-5 py-8 text-text-primary sm:px-8">
      <header className="flex items-center justify-between gap-4 border-border border-b pb-6">
        <Link
          href="/"
          className="text-sm text-text-secondary hover:text-text-primary"
        >
          Tableros
        </Link>
        <SignOutButton />
      </header>
      <section className="mt-10 rounded-2xl border border-border bg-surface-raised p-6 sm:p-8">
        <h1 className="font-bold font-display text-3xl tracking-tight">
          Cuenta y preferencias
        </h1>
        <p className="mt-3 max-w-xl text-sm text-text-secondary leading-6">
          El tema se sincroniza con tu cuenta. Sistema sigue la apariencia de
          este dispositivo.
        </p>
        <div className="mt-8 max-w-xs">
          <ThemePreferenceControl />
        </div>
      </section>
    </main>
  );
}
