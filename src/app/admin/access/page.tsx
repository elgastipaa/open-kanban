import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { AccessManager } from "@/components/auth/access-manager";
import { SignOutButton } from "@/components/auth/sign-out-button";
import { AdminBoardRecovery } from "@/components/board/admin-board-recovery";
import { Logo } from "@/components/ui/logo";
import { resolveApplicationAccess } from "@/lib/auth";
import type { AdminRecoverableBoard } from "@/lib/db/boards";
import { listAdminRecoverableBoards } from "@/lib/db/boards";
import { createClient } from "@/lib/supabase/server";

export default async function AccessAdminPage() {
  const supabase = await createClient();
  const { data } = await supabase.auth.getUser();
  if (!data.user) redirect("/login?next=%2Fadmin%2Faccess");

  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active" || !access.isAdmin) notFound();

  const { data: entries, error } = await supabase.rpc("admin_list_access");
  let recoverableBoards: AdminRecoverableBoard[] = [];
  let recoveryLoadError = false;
  try {
    recoverableBoards = await listAdminRecoverableBoards(supabase);
  } catch {
    recoveryLoadError = true;
  }

  return (
    <main className="mx-auto min-h-dvh max-w-4xl bg-surface-base px-5 py-8 text-text-primary sm:px-8">
      <header className="flex items-center justify-between gap-4 border-border border-b pb-6">
        <Logo />
        <div className="flex items-center gap-3">
          <Link
            href="/account"
            className="rounded-lg border border-border px-4 py-2 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary"
          >
            Cuenta
          </Link>
          <SignOutButton />
        </div>
      </header>
      <div className="mt-10">
        <p className="text-sm text-text-secondary">Administración</p>
        <h1 className="mt-1 font-bold font-display text-3xl">Accesos</h1>
        <p className="mt-3 max-w-2xl text-sm text-text-secondary leading-6">
          Habilita una dirección de Google. La primera sesión con identidad
          verificada la vincula a una cuenta de Auth; una URL por sí sola no
          concede acceso.
        </p>
      </div>
      {error ? (
        <p
          className="mt-8 rounded-xl border border-priority-urgent/30 bg-priority-urgent/10 p-4 text-priority-urgent text-sm"
          role="alert"
        >
          No se pudieron cargar los accesos.
        </p>
      ) : (
        <AccessManager entries={entries ?? []} />
      )}
      <AdminBoardRecovery
        boards={recoverableBoards}
        loadError={recoveryLoadError}
      />
    </main>
  );
}
