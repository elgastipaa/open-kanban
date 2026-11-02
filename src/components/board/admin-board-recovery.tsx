"use client";

import { IconRefresh } from "@tabler/icons-react";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  adminMayResolveBoardRecovery,
  formatBoardRecoveryDates,
  prepareBoardRestoreCommand,
} from "@/lib/board-recovery-flow";
import {
  type AdminRecoverableBoard,
  BoardRecoveryError,
  type BoardRecoveryOwner,
  listBoardRecoveryOwners,
  restoreBoard,
} from "@/lib/db/boards";
import { createClient } from "@/lib/supabase/client";
import { generateUUID } from "@/lib/utils";

interface RestoreCommand {
  operationId: string;
  ownerId: string;
}

function formatDeadline(value: string): string {
  return new Intl.DateTimeFormat("es-AR", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function adminRestoreError(error: unknown): string {
  if (error instanceof BoardRecoveryError && error.reason === "access_denied") {
    return "La autoridad administrativa cambió. Actualiza la página para revisar el estado.";
  }
  if (error instanceof BoardRecoveryError && error.reason === "conflict") {
    return "El tablero o el sucesor cambió durante la recuperación. Actualiza la lista.";
  }
  return "No se pudo confirmar la restauración. Reintenta para consultar la misma operación.";
}

export function AdminBoardRecovery({
  boards: initialBoards,
  loadError,
}: {
  boards: AdminRecoverableBoard[];
  loadError: boolean;
}) {
  const router = useRouter();
  const [boards, setBoards] = useState(initialBoards);
  const [ownersByBoard, setOwnersByBoard] = useState<
    Record<string, BoardRecoveryOwner[]>
  >({});
  const [selectedOwnerByBoard, setSelectedOwnerByBoard] = useState<
    Record<string, string>
  >({});
  const [commands, setCommands] = useState<Record<string, RestoreCommand>>({});
  const [busyId, setBusyId] = useState<string | null>(null);
  const [loadingOwnersId, setLoadingOwnersId] = useState<string | null>(null);
  const [message, setMessage] = useState("");
  const [errorMessage, setErrorMessage] = useState("");
  const ownerLoadGeneration = useRef(0);

  useEffect(() => setBoards(initialBoards), [initialBoards]);

  async function loadOwners(board: AdminRecoverableBoard) {
    const generation = ++ownerLoadGeneration.current;
    setLoadingOwnersId(board.id);
    setErrorMessage("");
    try {
      const owners = await listBoardRecoveryOwners(createClient(), board.id);
      if (generation !== ownerLoadGeneration.current) return;
      setOwnersByBoard((current) => ({ ...current, [board.id]: owners }));
      setSelectedOwnerByBoard((current) => ({
        ...current,
        [board.id]: current[board.id] ?? owners[0]?.user_id ?? "",
      }));
    } catch {
      setErrorMessage(
        "No se pudieron cargar las opciones de dueño habilitado.",
      );
    } finally {
      if (generation === ownerLoadGeneration.current) setLoadingOwnersId(null);
    }
  }

  async function restore(board: AdminRecoverableBoard) {
    const selectedOwnerId = selectedOwnerByBoard[board.id];
    const commandDecision = prepareBoardRestoreCommand(
      selectedOwnerId ?? "",
      commands[board.id] ?? null,
      generateUUID,
    );
    if (commandDecision.kind === "owner_required") {
      setErrorMessage(
        "Selecciona una identidad habilitada para recibir el tablero.",
      );
      return;
    }
    if (commandDecision.kind === "owner_locked") {
      setErrorMessage(
        "Hay una operación sin confirmar. Reintenta con el mismo dueño antes de cambiar la selección.",
      );
      return;
    }
    const command = commandDecision.command;
    setCommands((current) => ({ ...current, [board.id]: command }));
    setBusyId(board.id);
    setMessage("");
    setErrorMessage("");
    try {
      const result = await restoreBoard(
        createClient(),
        board.id,
        command.operationId,
        command.ownerId,
      );
      if (result.status === "confirmed") {
        setCommands((current) => {
          const next = { ...current };
          delete next[board.id];
          return next;
        });
        setBoards((current) => current.filter((item) => item.id !== board.id));
        setMessage(
          `Se restauró «${board.name}» y se asignó un dueño habilitado.`,
        );
        router.refresh();
      } else if (result.status === "expired") {
        setCommands((current) => {
          const next = { ...current };
          delete next[board.id];
          return next;
        });
        setErrorMessage(`Venció el plazo de recuperación de «${board.name}».`);
        router.refresh();
      } else if (result.status === "owner_required") {
        setCommands((current) => {
          const next = { ...current };
          delete next[board.id];
          return next;
        });
        setErrorMessage(
          "Este tablero requiere que elijas un nuevo dueño habilitado.",
        );
      } else {
        setCommands((current) => {
          const next = { ...current };
          delete next[board.id];
          return next;
        });
        setErrorMessage("No se pudo restaurar el tablero con esa elección.");
      }
    } catch (error) {
      setErrorMessage(adminRestoreError(error));
    } finally {
      setBusyId(null);
    }
  }

  if (boards.length === 0 && !loadError) return null;

  return (
    <section className="mt-8 rounded-2xl border border-border bg-surface-raised p-5">
      <div className="flex items-start gap-3">
        <IconRefresh
          aria-hidden="true"
          className="mt-0.5 text-text-secondary"
          size={20}
        />
        <div className="min-w-0 flex-1">
          <h2 className="font-semibold">Recuperación de tableros</h2>
          <p className="mt-1 text-sm text-text-secondary">
            Solo se muestran nombre, dueño y plazo. La administración no recibe
            acceso al contenido del tablero.
          </p>
        </div>
      </div>

      {loadError ? (
        <p className="mt-4 text-priority-urgent text-sm" role="alert">
          No se pudo cargar la lista de recuperación.
        </p>
      ) : null}
      {boards.length > 0 ? (
        <ul className="mt-4 divide-y divide-white/10">
          {boards.map((board) => {
            const owners = ownersByBoard[board.id];
            const command = commands[board.id];
            const adminCanResolve = adminMayResolveBoardRecovery(
              board.owner_is_valid,
            );
            return (
              <li key={board.id} className="py-4">
                <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                  <div className="min-w-0">
                    <p className="truncate font-medium">{board.name}</p>
                    <p className="mt-1 text-text-muted text-xs">
                      /{board.slug} ·{" "}
                      {formatBoardRecoveryDates(
                        board.deleted_at,
                        board.expires_at,
                        formatDeadline,
                      )}
                    </p>
                    <p className="mt-2 text-sm text-text-secondary">
                      {board.owner_is_valid
                        ? "El dueño habilitado actual conserva la autoridad de recuperación."
                        : board.recovery_owner_id
                          ? "Hay una identidad asignada a la recuperación. Puedes reemplazarla al elegir un nuevo dueño para restaurar."
                          : board.active_member_count > 1
                            ? "El dueño actual ya no es válido. Elige otro miembro habilitado del tablero."
                            : "No queda un dueño vigente. Elige una identidad habilitada para incorporarla como nuevo dueño."}
                    </p>
                  </div>
                  {adminCanResolve ? (
                    <Button
                      variant="primary"
                      size="sm"
                      disabled={busyId !== null || loadingOwnersId === board.id}
                      onClick={() => loadOwners(board)}
                    >
                      {loadingOwnersId === board.id
                        ? "Cargando opciones…"
                        : owners
                          ? "Actualizar opciones"
                          : "Elegir dueño"}
                    </Button>
                  ) : null}
                </div>
                {adminCanResolve && owners ? (
                  <div className="mt-3 flex flex-col gap-3 sm:flex-row sm:items-end">
                    <label className="flex-1">
                      <span className="mb-2 block text-sm text-text-secondary">
                        Nuevo dueño habilitado
                      </span>
                      <select
                        value={selectedOwnerByBoard[board.id] ?? ""}
                        disabled={busyId !== null || Boolean(command)}
                        onChange={(event) =>
                          setSelectedOwnerByBoard((current) => ({
                            ...current,
                            [board.id]: event.target.value,
                          }))
                        }
                        className="min-h-11 w-full rounded-lg border border-border bg-surface-base px-3 text-text-primary outline-none focus:border-accent disabled:opacity-60"
                      >
                        <option value="">Selecciona una identidad</option>
                        {owners.map((owner) => (
                          <option key={owner.user_id} value={owner.user_id}>
                            {owner.email}
                            {owner.is_admin ? " · Administrador" : ""}
                          </option>
                        ))}
                      </select>
                    </label>
                    <Button
                      variant="primary"
                      size="sm"
                      disabled={busyId !== null || owners.length === 0}
                      onClick={() => restore(board)}
                    >
                      {busyId === board.id
                        ? "Restaurando…"
                        : "Asignar y restaurar"}
                    </Button>
                  </div>
                ) : null}
                {adminCanResolve && owners?.length === 0 ? (
                  <output className="mt-3 text-priority-medium text-sm">
                    No hay una identidad habilitada elegible para este tablero.
                  </output>
                ) : null}
              </li>
            );
          })}
        </ul>
      ) : null}
      {message ? (
        <output className="mt-3 text-sm text-status-success">{message}</output>
      ) : null}
      {errorMessage ? (
        <p className="mt-3 text-priority-urgent text-sm" role="alert">
          {errorMessage}
        </p>
      ) : null}
    </section>
  );
}
