import type { Metadata } from "next";
import Link from "next/link";
import { PendingInvitations } from "@/components/auth/pending-invitations";
import { SignInButton } from "@/components/auth/sign-in-button";
import { SignOutButton } from "@/components/auth/sign-out-button";
import { BoardFavoritesList } from "@/components/board/board-favorites-list";
import { CreateBoardForm } from "@/components/board/create-board-form";
import { MyBoardRecovery } from "@/components/board/my-board-recovery";
import { Logo } from "@/components/ui/logo";
import { resolveApplicationAccess } from "@/lib/auth";
import { listMyBoardFavoriteIds } from "@/lib/db/board-favorites";
import { listMyRecoverableBoards } from "@/lib/db/boards";
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
      <main className="flex min-h-dvh items-center justify-center bg-surface-base px-5 py-12 text-text-primary">
        <section className="w-full max-w-md rounded-3xl border border-border bg-surface-raised p-8 shadow-2xl sm:p-10">
          <Logo />
          <h1 className="mt-10 font-bold font-display text-3xl tracking-tight">
            Tus tableros, en privado
          </h1>
          <p className="mt-3 text-sm text-text-secondary leading-6">
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
      <main className="flex min-h-dvh items-center justify-center bg-surface-base px-5 py-12 text-text-primary">
        <section className="w-full max-w-lg rounded-3xl border border-border bg-surface-raised p-8 shadow-2xl sm:p-10">
          <div className="flex items-center justify-between gap-4">
            <Logo />
            <SignOutButton />
          </div>
          <h1 className="mt-10 font-bold font-display text-3xl tracking-tight">
            Acceso a OpenKanban
          </h1>
          <output className="mt-3 text-sm text-text-secondary leading-6">
            {message}
          </output>
          <p className="mt-3 text-sm text-text-muted leading-6">
            Si acabas de recibir habilitación, cierra la sesión y vuelve a
            entrar con la cuenta de Google autorizada.
          </p>
        </section>
      </main>
    );
  }

  const boardsPromise = supabase.rpc("list_my_boards");
  const favoritesPromise = listMyBoardFavoriteIds(supabase).then(
    (ids) => ({ ids, error: false }),
    () => ({ ids: [], error: true }),
  );
  const [
    { data: boardsData, error: boardsError },
    { ids: favoriteBoardIds, error: favoritesLoadError },
  ] = await Promise.all([boardsPromise, favoritesPromise]);
  const boards = (boardsData ?? []) as Board[];
  let invitations: PendingBoardInvitation[] = [];
  let invitationsLoadError = false;
  let recoverableBoards: Awaited<ReturnType<typeof listMyRecoverableBoards>> =
    [];
  let recoveryLoadError = false;
  try {
    invitations = await listMyPendingBoardInvitations(supabase);
  } catch {
    invitationsLoadError = true;
  }
  try {
    recoverableBoards = await listMyRecoverableBoards(supabase);
  } catch {
    recoveryLoadError = true;
  }

  return (
    <main className="mx-auto min-h-dvh max-w-5xl bg-surface-base px-5 py-8 text-text-primary sm:px-8">
      <header className="flex flex-wrap items-center justify-between gap-4 border-border border-b pb-6">
        <Logo />
        <div className="flex flex-wrap items-center justify-end gap-3">
          <Link
            href="/account"
            className="rounded-lg border border-border px-4 py-2 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary"
          >
            Cuenta
          </Link>
          <Link
            href="/my-tasks?order=due"
            className="rounded-lg border border-border px-4 py-2 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary"
          >
            Mis tareas
          </Link>
          {access.isAdmin ? (
            <Link
              href="/admin/access"
              className="rounded-lg border border-border px-4 py-2 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary"
            >
              Administrar accesos
            </Link>
          ) : null}
          <SignOutButton />
        </div>
      </header>

      <section className="mt-12 flex flex-col justify-between gap-6 sm:flex-row sm:items-end">
        <div>
          <p className="text-sm text-text-secondary">Espacio privado</p>
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

      <MyBoardRecovery
        boards={recoverableBoards}
        loadError={recoveryLoadError}
      />

      <BoardFavoritesList
        boards={boards}
        boardsLoadError={Boolean(boardsError)}
        favoriteBoardIds={favoriteBoardIds}
        favoritesLoadError={favoritesLoadError}
      />
    </main>
  );
}
