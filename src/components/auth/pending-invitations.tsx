"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import type { PendingBoardInvitation } from "@/lib/db/invitations";
import {
  acceptDirectInvitation,
  rejectInvitation,
} from "@/lib/invitation-actions";
import {
  completeInvitationOperation,
  getOrCreateInvitationOperation,
} from "@/lib/invitation-operation";

export function PendingInvitations({
  invitations,
  loadError,
}: {
  invitations: PendingBoardInvitation[];
  loadError: boolean;
}) {
  const router = useRouter();
  const [pending, setPending] = useState(invitations);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  async function accept(id: string) {
    const scope = `accept-direct:${id}`;
    const operation = getOrCreateInvitationOperation(scope, false);
    setBusyId(id);
    setError("");
    setMessage("");
    try {
      const result = await acceptDirectInvitation(id, operation.operationId);
      if (result.status !== "ok") {
        setError(result.message);
        return;
      }
      if (
        result.data.status === "unavailable" ||
        result.data.status === "expired_unknown"
      ) {
        completeInvitationOperation(scope);
        setError("Esta invitación ya no está disponible. Actualiza la lista.");
        setPending((current) =>
          current.filter((invitation) => invitation.id !== id),
        );
        return;
      }
      completeInvitationOperation(scope);
      router.push(`/${result.data.board_slug}`);
    } catch {
      setError(
        "No se pudo confirmar la aceptación. Reintenta esta misma solicitud.",
      );
    } finally {
      setBusyId(null);
    }
  }

  async function reject(id: string) {
    setBusyId(id);
    setError("");
    setMessage("");
    const result = await rejectInvitation(id);
    setBusyId(null);
    if (result.status !== "ok" || !result.data) {
      setError(
        result.status === "unavailable"
          ? result.message
          : "Esta invitación ya no está disponible. Actualiza la lista.",
      );
      return;
    }
    setPending((current) =>
      current.filter((invitation) => invitation.id !== id),
    );
    setMessage("Invitación rechazada.");
  }

  return (
    <section className="mt-8" aria-labelledby="pending-invitations-title">
      <div>
        <p className="text-neutral-400 text-sm">
          Compartieron un tablero contigo
        </p>
        <h2
          id="pending-invitations-title"
          className="mt-1 font-semibold text-xl"
        >
          Invitaciones pendientes
        </h2>
      </div>
      {loadError ? (
        <p
          className="mt-4 rounded-xl border border-red-400/20 bg-red-400/5 p-4 text-red-200 text-sm"
          role="alert"
        >
          No se pudieron cargar las invitaciones. Inténtalo de nuevo más tarde.
        </p>
      ) : pending.length > 0 ? (
        <ul className="mt-4 grid gap-3 sm:grid-cols-2">
          {pending.map((invitation) => (
            <li
              key={invitation.id}
              className="rounded-2xl border border-white/10 bg-neutral-950 p-5"
            >
              <p className="font-semibold">{invitation.board_name}</p>
              <p className="mt-2 text-neutral-400 text-sm">
                Invitó {invitation.inviter_email} · rol colaborador
              </p>
              <p className="mt-2 text-neutral-500 text-xs">
                Vence{" "}
                {new Intl.DateTimeFormat("es-AR", {
                  dateStyle: "medium",
                  timeStyle: "short",
                }).format(new Date(invitation.expires_at))}
              </p>
              <div className="mt-4 flex gap-2">
                <button
                  type="button"
                  onClick={() => void accept(invitation.id)}
                  disabled={busyId !== null}
                  className="rounded-lg bg-white px-4 py-2 font-semibold text-neutral-950 text-sm disabled:opacity-50"
                >
                  {busyId === invitation.id ? "Aceptando…" : "Aceptar"}
                </button>
                <button
                  type="button"
                  onClick={() => void reject(invitation.id)}
                  disabled={busyId !== null}
                  className="rounded-lg border border-white/15 px-4 py-2 text-neutral-300 text-sm hover:bg-white/5 disabled:opacity-50"
                >
                  Rechazar
                </button>
              </div>
            </li>
          ))}
        </ul>
      ) : (
        <p className="mt-4 rounded-xl border border-white/10 bg-neutral-950 p-4 text-neutral-400 text-sm">
          No tienes invitaciones pendientes.
        </p>
      )}
      {error ? (
        <p
          className="mt-3 text-red-200 text-sm"
          role="alert"
          aria-live="assertive"
        >
          {error}
        </p>
      ) : null}
      {message ? (
        <output className="mt-3 text-neutral-300 text-sm" aria-live="polite">
          {message}
        </output>
      ) : null}
    </section>
  );
}
