"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { getInvitationAcceptanceResolution } from "@/lib/invitation-acceptance-state";
import { acceptInvitationLink } from "@/lib/invitation-actions";
import type { InvitationPreview } from "@/lib/invitation-contract";
import {
  completeInvitationOperation,
  getOrCreateInvitationOperation,
} from "@/lib/invitation-operation";

export function InvitationAcceptance({
  token,
  preview,
}: {
  token: string;
  preview: Extract<InvitationPreview, { status: "available" }>;
}) {
  const router = useRouter();
  const [isAccepting, setIsAccepting] = useState(false);
  const [error, setError] = useState("");
  const [requiresReconciliation, setRequiresReconciliation] = useState(false);

  async function accept() {
    const scope = `accept-link:${token}`;
    const operation = getOrCreateInvitationOperation(scope, false);
    setIsAccepting(true);
    setError("");
    try {
      const result = await acceptInvitationLink(token, operation.operationId);
      if (result.status !== "ok") {
        setError(result.message);
        return;
      }
      if (
        result.data.status === "unavailable" ||
        result.data.status === "expired_unknown"
      ) {
        completeInvitationOperation(scope);
        const resolution = getInvitationAcceptanceResolution(
          result.data.status,
        );
        setError(resolution.message);
        setRequiresReconciliation(resolution.requiresReconciliation);
        return;
      }
      completeInvitationOperation(scope);
      router.replace(`/${result.data.board_slug}`);
    } catch {
      setError(
        "No se pudo confirmar la aceptación. Reintenta esta misma solicitud.",
      );
    } finally {
      setIsAccepting(false);
    }
  }

  return (
    <main className="flex min-h-dvh items-center justify-center bg-black px-5 py-12 text-white">
      <section className="w-full max-w-lg rounded-3xl border border-white/10 bg-neutral-950 p-8 shadow-2xl sm:p-10">
        <p className="text-neutral-400 text-sm">Invitación a colaborar</p>
        <h1 className="mt-2 font-bold font-display text-3xl tracking-tight">
          {preview.board_name}
        </h1>
        <p className="mt-4 text-neutral-300 text-sm leading-6">
          {preview.inviter} te invitó como colaborador. Al aceptar, las personas
          con acceso a este tablero podrán ver su contenido.
        </p>
        <p className="mt-2 text-neutral-500 text-sm">
          La invitación se usa una vez y vence en 72 horas.
        </p>
        <div className="mt-8 flex flex-col gap-3 sm:flex-row">
          <button
            type="button"
            onClick={() => void accept()}
            disabled={isAccepting || requiresReconciliation}
            className="min-h-11 flex-1 rounded-xl bg-white px-5 py-3 font-semibold text-neutral-950 transition hover:bg-neutral-200 disabled:opacity-60"
          >
            {isAccepting
              ? "Aceptando…"
              : requiresReconciliation
                ? "Aceptación pendiente de verificar"
                : "Aceptar y abrir tablero"}
          </button>
          <Link
            href="/"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-white/15 px-5 py-3 text-neutral-300 text-sm transition hover:bg-white/5"
          >
            Cancelar
          </Link>
        </div>
        {error ? (
          <p
            className="mt-4 rounded-lg border border-red-400/20 bg-red-400/5 p-3 text-red-200 text-sm"
            role="alert"
          >
            {error}
          </p>
        ) : null}
        {requiresReconciliation ? (
          <Link
            href="/"
            className="mt-3 inline-flex min-h-11 items-center justify-center rounded-xl border border-white/15 px-5 py-3 text-neutral-200 text-sm transition hover:bg-white/5"
          >
            Ir a Tableros y verificar acceso
          </Link>
        ) : null}
      </section>
    </main>
  );
}
