import type { Metadata } from "next";
import Link from "next/link";
import { PendingInvitations } from "@/components/auth/pending-invitations";
import { SignInButton } from "@/components/auth/sign-in-button";
import { SignOutButton } from "@/components/auth/sign-out-button";
import { CreateBoardForm } from "@/components/board/create-board-form";
import { Logo } from "@/components/ui/logo";
import { resolveApplicationAccess } from "@/lib/auth";
import type { PendingBoardInvitation } from "@/lib/db/invitations";
import { listMyPendingBoardInvitations } from "@/lib/db/invitations";
import { createClient } from "@/lib/supabase/server";
import type { Board } from "@/lib/types";

export const metadata: Metadata = {
  title: "OpenKanban",
  description: "Acceso privado a tus tableros de OpenKanban.",
  robots: { index: false, follow: false, nocache: true },
};

const accessMessages: Record<string, string> = {
  google_required: "Para usar OpenKanban debes iniciar sesión con Google.",
  not_enabled: "Tu cuenta todavía no está habilitada para OpenKanban.",
  suspended: "El acceso de esta cuenta está suspendido.",
  error: "No se pudo comprobar el acceso. Inténtalo de nuevo más tarde.",
};

export default async function HomePage() {
  const supabase = await createClient();
  const { data: authData } = await supabase.auth.getUser();

  if (!authData.user) {
    return (
      <main className="flex min-h-dvh items-center justify-center bg-black px-5 py-12 text-white">
        <section className="w-full max-w-md rounded-3xl border border-white/10 bg-neutral-950 p-8 shadow-2xl sm:p-10">
          <Logo />
          <h1 className="mt-10 font-bold font-display text-3xl tracking-tight">
            Tus tableros, en privado
          </h1>
          <p className="mt-3 text-neutral-400 text-sm leading-6">
            Inicia sesión con Google. El acceso a OpenKanban requiere una
            habilitación explícita.
          </p>
          <div className="mt-8">
            <SignInButton />
          </div>
        </section>
      </main>
    );
  }

  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active") {
    const message =
      accessMessages[access.status] ??
      "No se pudo comprobar el acceso. Inténtalo de nuevo más tarde.";
    return (
      <main className="flex min-h-dvh items-center justify-center bg-black px-5 py-12 text-white">
        <section className="w-full max-w-lg rounded-3xl border border-white/10 bg-neutral-950 p-8 shadow-2xl sm:p-10">
          <div className="flex items-center justify-between gap-4">
            <Logo />
            <SignOutButton />
          </div>
          <h1 className="mt-10 font-bold font-display text-3xl tracking-tight">
            Acceso a OpenKanban
          </h1>
          <output className="mt-3 text-neutral-300 text-sm leading-6">
            {message}
          </output>
          <p className="mt-3 text-neutral-500 text-sm leading-6">
            Si acabas de recibir habilitación, cierra la sesión y vuelve a
            entrar con la cuenta de Google autorizada.
          </p>
        </section>
      </main>
    );
  }

  const { data: boardsData, error: boardsError } =
    await supabase.rpc("list_my_boards");
  const boards = (boardsData ?? []) as Board[];
  let invitations: PendingBoardInvitation[] = [];
  let invitationsLoadError = false;
  try {
    invitations = await listMyPendingBoardInvitations(supabase);
  } catch {
    invitationsLoadError = true;
  }

  return (
    <main className="mx-auto min-h-dvh max-w-5xl bg-black px-5 py-8 text-white sm:px-8">
      <header className="flex items-center justify-between gap-4 border-white/10 border-b pb-6">
        <Logo />
        <div className="flex items-center gap-3">
          {access.isAdmin ? (
            <Link
              href="/admin/access"
              className="rounded-lg border border-white/15 px-4 py-2 text-neutral-300 text-sm transition hover:bg-white/5 hover:text-white"
            >
              Administrar accesos
            </Link>
          ) : null}
          <SignOutButton />
        </div>
      </header>

      <section className="mt-12 flex flex-col justify-between gap-6 sm:flex-row sm:items-end">
        <div>
          <p className="text-neutral-400 text-sm">Espacio privado</p>
          <h1 className="mt-1 font-bold font-display text-4xl tracking-tight">
            Tus tableros
          </h1>
        </div>
        <CreateBoardForm principalId={authData.user.id} />
      </section>

      {invitations.length > 0 || invitationsLoadError ? (
        <PendingInvitations
          invitations={invitations}
          loadError={invitationsLoadError}
        />
      ) : null}

      {boardsError ? (
        <p
          className="mt-8 rounded-xl border border-red-400/20 bg-red-400/5 p-4 text-red-200 text-sm"
          role="alert"
        >
          No se pudieron cargar tus tableros.
        </p>
      ) : boards.length === 0 ? (
        <p className="mt-8 rounded-2xl border border-white/15 border-dashed p-10 text-center text-neutral-400 text-sm">
          Todavía no tienes tableros. Acepta una invitación o crea uno para
          empezar.
        </p>
      ) : (
        <ul className="mt-8 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {boards.map((board) => (
            <li key={board.id}>
              <Link
                href={`/${board.slug}`}
                className="block rounded-2xl border border-white/10 bg-neutral-950 p-5 transition hover:border-white/25 hover:bg-neutral-900"
              >
                <span className="block truncate font-semibold">
                  {board.name}
                </span>
                <span className="mt-2 block text-neutral-500 text-xs">
                  {board.role === "owner"
                    ? "Propietario"
                    : "Compartido contigo"}
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </main>
  );
}
