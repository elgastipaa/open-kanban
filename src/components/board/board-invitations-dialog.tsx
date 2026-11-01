"use client";

import { IconLink, IconRefresh, IconUserPlus } from "@tabler/icons-react";
import { useCallback, useEffect, useState } from "react";
import { Modal } from "@/components/ui/modal";
import type { BoardInvitation } from "@/lib/db/invitations";
import {
  createDirectInvitation,
  createInvitationLink,
  loadBoardInvitations,
  renewInvitation,
  revokeInvitation,
} from "@/lib/invitation-actions";

interface BoardInvitationsDialogProps {
  open: boolean;
  onClose: () => void;
  slug: string;
}

function invitationStatusLabel(
  status: BoardInvitation["invitation_status"],
): string {
  switch (status) {
    case "pending":
      return "Pendiente";
    case "expired":
      return "Vencida";
    case "revoked":
      return "Revocada";
  }
}

function invitationDate(value: string): string {
  const date = new Date(value);
  if (!Number.isFinite(date.valueOf())) return "Fecha no disponible";
  return new Intl.DateTimeFormat("es-AR", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

export function BoardInvitationsDialog({
  open,
  onClose,
  slug,
}: BoardInvitationsDialogProps) {
  const [invitations, setInvitations] = useState<BoardInvitation[]>([]);
  const [email, setEmail] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [message, setMessage] = useState("");
  const [linkUrl, setLinkUrl] = useState<string | null>(null);
  const [linkMessage, setLinkMessage] = useState("");

  const refresh = useCallback(async () => {
    setIsLoading(true);
    const result = await loadBoardInvitations(slug);
    setIsLoading(false);
    if (result.status !== "ok") {
      setError(result.message);
      return;
    }
    setError(null);
    setInvitations(result.data);
  }, [slug]);

  useEffect(() => {
    if (open) {
      setMessage("");
      setError(null);
      void refresh();
    }
  }, [open, refresh]);

  async function inviteDirect(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setMessage("");
    setIsSaving(true);
    const result = await createDirectInvitation(slug, email);
    setIsSaving(false);
    if (result.status !== "ok") {
      setError(result.message);
      return;
    }

    switch (result.data.status) {
      case "already_member":
        setMessage("Ya es miembro de este tablero.");
        break;
      case "existing":
        setMessage("Ya hay una invitación directa pendiente para esa persona.");
        break;
      case "expired":
        setMessage(
          "La invitación venció. Renueva su fecha de forma explícita.",
        );
        break;
      case "created":
        setMessage(
          "Invitación creada. La persona puede aceptarla desde Tableros.",
        );
        setEmail("");
        break;
    }
    await refresh();
  }

  async function createLink() {
    setError(null);
    setMessage("");
    setLinkMessage("");
    setIsSaving(true);
    const result = await createInvitationLink(slug);
    setIsSaving(false);
    if (result.status !== "ok") {
      setError(result.message);
      return;
    }
    setLinkUrl(
      new URL(
        `/invite/${result.data.token}`,
        window.location.origin,
      ).toString(),
    );
    setLinkMessage("Enlace creado. Caduca en 72 horas y se usa una sola vez.");
    await refresh();
  }

  async function copyLink() {
    if (!linkUrl) return;
    try {
      await navigator.clipboard.writeText(linkUrl);
      setLinkMessage("Enlace copiado.");
    } catch {
      setLinkMessage(
        "No se pudo copiar. Selecciona el enlace para copiarlo manualmente.",
      );
    }
  }

  async function renew(invitation: BoardInvitation) {
    setError(null);
    setMessage("");
    setIsSaving(true);
    const result = await renewInvitation(slug, invitation.id);
    setIsSaving(false);
    if (result.status !== "ok") {
      setError(result.message);
      return;
    }
    if (result.data.status === "not_expired") {
      setMessage("La invitación todavía está vigente.");
    } else if (result.data.status === "unavailable") {
      setError("La invitación ya no está disponible para renovar.");
    } else if (result.data.token) {
      setLinkUrl(
        new URL(
          `/invite/${result.data.token}`,
          window.location.origin,
        ).toString(),
      );
      setLinkMessage("Enlace renovado. El enlace anterior dejó de funcionar.");
    } else {
      setMessage("Invitación directa renovada por 72 horas.");
    }
    await refresh();
  }

  async function revoke(invitation: BoardInvitation) {
    setError(null);
    setMessage("");
    setIsSaving(true);
    const result = await revokeInvitation(slug, invitation.id);
    setIsSaving(false);
    if (result.status !== "ok") {
      setError(result.message);
      return;
    }
    if (!result.data) {
      setError("La invitación ya no está disponible.");
      return;
    }
    setMessage("Invitación revocada.");
    await refresh();
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Invitaciones y colaboración"
      fullScreenMobile
    >
      <div className="space-y-6 text-text-primary">
        <form onSubmit={inviteDirect} className="space-y-3">
          <label
            className="block font-medium text-sm"
            htmlFor="board-invite-email"
          >
            Invitar a una persona habilitada
          </label>
          <div className="flex flex-col gap-2 sm:flex-row">
            <input
              id="board-invite-email"
              type="email"
              autoComplete="email"
              required
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              placeholder="persona@ejemplo.com"
              disabled={isSaving}
              className="min-h-11 min-w-0 flex-1 rounded-lg border border-border bg-surface-base px-3 text-sm outline-none focus:border-accent"
            />
            <button
              type="submit"
              disabled={isSaving}
              className="inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-accent px-4 font-semibold text-sm text-text-inverse disabled:opacity-50"
            >
              <IconUserPlus size={16} aria-hidden="true" />
              Invitar
            </button>
          </div>
          <p className="text-text-muted text-xs">
            La invitación se muestra en Tableros. No se envía correo automático.
          </p>
        </form>

        <section className="space-y-3 border-border border-t pt-5">
          <div>
            <h3 className="font-semibold text-sm">Enlace genérico</h3>
            <p className="mt-1 text-text-muted text-xs leading-5">
              Cualquier persona habilitada con el enlace puede aceptarlo una
              vez. Caduca en 72 horas.
            </p>
          </div>
          <button
            type="button"
            onClick={() => void createLink()}
            disabled={isSaving}
            className="inline-flex min-h-10 items-center gap-2 rounded-lg border border-border px-3 text-sm hover:bg-surface-raised disabled:opacity-50"
          >
            <IconLink size={16} aria-hidden="true" />
            Crear enlace
          </button>
          {linkUrl ? (
            <div className="space-y-2">
              <label
                className="block font-medium text-xs"
                htmlFor="board-invite-link"
              >
                Enlace de invitación
              </label>
              <div className="flex gap-2">
                <input
                  id="board-invite-link"
                  readOnly
                  value={linkUrl}
                  onFocus={(event) => event.currentTarget.select()}
                  className="min-h-10 min-w-0 flex-1 rounded-lg border border-border bg-surface-base px-3 text-xs"
                />
                <button
                  type="button"
                  onClick={() => void copyLink()}
                  className="rounded-lg border border-border px-3 text-xs hover:bg-surface-raised"
                >
                  Copiar
                </button>
              </div>
              <output className="text-text-muted text-xs" aria-live="polite">
                {linkMessage}
              </output>
            </div>
          ) : null}
        </section>

        <section className="space-y-3 border-border border-t pt-5">
          <div className="flex items-center justify-between gap-3">
            <h3 className="font-semibold text-sm">Invitaciones del tablero</h3>
            <button
              type="button"
              onClick={() => void refresh()}
              disabled={isLoading || isSaving}
              aria-label="Actualizar invitaciones"
              className="rounded-md p-2 text-text-muted hover:bg-surface-raised hover:text-text-primary disabled:opacity-50"
            >
              <IconRefresh size={16} aria-hidden="true" />
            </button>
          </div>
          {isLoading ? (
            <output className="text-sm text-text-muted" aria-live="polite">
              Cargando invitaciones…
            </output>
          ) : invitations.length > 0 ? (
            <ul className="divide-y divide-border rounded-lg border border-border">
              {invitations.map((invitation) => (
                <li
                  key={invitation.id}
                  className="flex flex-col gap-3 p-3 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div className="min-w-0">
                    <p className="truncate text-sm">
                      {invitation.invitation_type === "direct"
                        ? invitation.recipient_email
                        : "Enlace genérico"}
                    </p>
                    <p className="mt-1 text-text-muted text-xs">
                      {invitationStatusLabel(invitation.invitation_status)} ·
                      vence {invitationDate(invitation.expires_at)}
                    </p>
                  </div>
                  <div className="flex shrink-0 gap-2">
                    {invitation.invitation_status === "expired" ? (
                      <button
                        type="button"
                        onClick={() => void renew(invitation)}
                        disabled={isSaving}
                        className="rounded-md border border-border px-3 py-2 text-xs hover:bg-surface-raised disabled:opacity-50"
                      >
                        Renovar
                      </button>
                    ) : null}
                    {invitation.invitation_status !== "revoked" ? (
                      <button
                        type="button"
                        onClick={() => void revoke(invitation)}
                        disabled={isSaving}
                        className="rounded-md border border-border px-3 py-2 text-red-300 text-xs hover:bg-red-400/10 disabled:opacity-50"
                      >
                        Revocar
                      </button>
                    ) : null}
                  </div>
                </li>
              ))}
            </ul>
          ) : (
            <p className="rounded-lg border border-border border-dashed p-4 text-sm text-text-muted">
              Todavía no hay invitaciones para este tablero.
            </p>
          )}
        </section>

        {error ? (
          <p
            className="rounded-lg border border-red-400/30 bg-red-400/5 p-3 text-red-200 text-sm"
            role="alert"
          >
            {error}
          </p>
        ) : null}
        {message ? (
          <output className="text-sm text-text-secondary" aria-live="polite">
            {message}
          </output>
        ) : null}
      </div>
    </Modal>
  );
}
