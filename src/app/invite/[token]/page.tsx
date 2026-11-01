import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { InvitationAcceptance } from "@/components/auth/invitation-acceptance";
import { Logo } from "@/components/ui/logo";
import { resolveApplicationAccess } from "@/lib/auth";
import { previewBoardInvitation } from "@/lib/db/invitations";
import type { InvitationPreview } from "@/lib/invitation-contract";
import { createClient } from "@/lib/supabase/server";
import { invitationTokenSchema } from "@/lib/validations";

interface InvitationPageProps {
  params: Promise<{ token: string }>;
}

export const metadata: Metadata = {
  title: "Invitación a OpenKanban",
  description: "Revisa una invitación para colaborar en un tablero.",
  referrer: "no-referrer",
  robots: { index: false, follow: false, nocache: true },
};

function UnavailableInvitation({ message }: { message: string }) {
  return (
    <main className="flex min-h-dvh items-center justify-center bg-surface-base px-5 py-12 text-text-primary">
      <section className="w-full max-w-lg rounded-3xl border border-border bg-surface-raised p-8 shadow-2xl sm:p-10">
        <Logo />
        <h1 className="mt-10 font-bold font-display text-3xl tracking-tight">
          Invitación no disponible
        </h1>
        <p className="mt-3 text-sm text-text-secondary leading-6">{message}</p>
        <Link
          href="/"
          className="mt-8 inline-flex min-h-11 items-center justify-center rounded-xl border border-border px-5 py-3 text-sm text-text-secondary hover:bg-surface-hover"
        >
          Volver a Tableros
        </Link>
      </section>
    </main>
  );
}

export default async function InvitationPage({ params }: InvitationPageProps) {
  const { token } = await params;
  if (!invitationTokenSchema.safeParse(token).success) {
    return (
      <UnavailableInvitation message="Esta invitación ya no está disponible." />
    );
  }

  const supabase = await createClient();
  const { data: authData } = await supabase.auth.getUser();
  if (!authData.user) {
    redirect(`/login?next=${encodeURIComponent(`/invite/${token}`)}`);
  }

  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active") {
    return (
      <UnavailableInvitation message="Tu cuenta todavía no tiene acceso a OpenKanban. La invitación no se consumió." />
    );
  }

  let preview: InvitationPreview;
  try {
    preview = await previewBoardInvitation(supabase, token);
  } catch {
    preview = { status: "unavailable" } as const;
  }
  if (preview.status !== "available") {
    return (
      <UnavailableInvitation message="Esta invitación ya no está disponible." />
    );
  }

  return <InvitationAcceptance token={token} preview={preview} />;
}
