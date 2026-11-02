"use client";

import { IconRefresh } from "@tabler/icons-react";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { formatBoardRecoveryDates } from "@/lib/board-recovery-flow";
import {
  BoardRecoveryError,
  type RecoverableBoard,
  restoreBoard,
} from "@/lib/db/boards";
import { createClient } from "@/lib/supabase/client";
import { generateUUID } from "@/lib/utils";

function formatDeadline(value: string): string {
  return new Intl.DateTimeFormat("es-AR", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function ownerRestoreError(error: unknown): string {
  if (error instanceof BoardRecoveryError && error.reason === "access_denied") {
    return "La autoridad de recuperación cambió. Actualiza la página para revisar el estado.";
  }
  if (error instanceof BoardRecoveryError && error.reason === "conflict") {
    return "El tablero cambió mientras se restauraba. Actualiza la lista antes de continuar.";
  }
  return "No se pudo confirmar la restauración. Reintenta para consultar la misma operación.";
}

export function MyBoardRecovery({
  boards: initialBoards,
  loadError,
}: {
  boards: RecoverableBoard[];
  loadError: boolean;
}) {
  const router = useRouter();
  const [boards, setBoards] = useState(initialBoards);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [message, setMessage] = useState("");
  const [errorMessage, setErrorMessage] = useState("");
  const operationIds = useRef(new Map<string, string>());

  useEffect(() => setBoards(initialBoards), [initialBoards]);

  async function restore(board: RecoverableBoard) {
    const operationId = operationIds.current.get(board.id) ?? generateUUID();
    operationIds.current.set(board.id, operationId);
    setBusyId(board.id);
    setMessage("");
    setErrorMessage("");
    try {
      const result = await restoreBoard(createClient(), board.id, operationId);
      if (result.status === "confirmed") {
        operationIds.current.delete(board.id);
        setBoards((current) => current.filter((item) => item.id !== board.id));
        setMessage(`Se restauró «${board.name}».`);
        router.refresh();
      } else if (result.status === "expired") {
        operationIds.current.delete(board.id);
        setErrorMessage(`Venció el plazo de recuperación de «${board.name}».`);
        router.refresh();
      } else {
        setErrorMessage(
          "No se pudo restaurar el tablero con la autoridad actual.",
        );
      }
    } catch (error) {
      setErrorMessage(ownerRestoreError(error));
    } finally {
      setBusyId(null);
    }
  }

  if (boards.length === 0 && !loadError) return null;

  return (
    <section className="mt-8 rounded-2xl border border-priority-medium/20 bg-priority-medium/10 p-5">
      <div className="flex items-start gap-3">
        <IconRefresh
          aria-hidden="true"
          className="mt-0.5 text-priority-medium"
          size={20}
        />
        <div className="min-w-0 flex-1">
          <h2 className="font-semibold text-priority-medium">
            Tableros en recuperación
          </h2>
          <p className="mt-1 text-sm text-text-secondary">
            El tablero y su contenido permanecen ocultos hasta restaurarlo. Las
            invitaciones revocadas no se reactivan.
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
          {boards.map((board) => (
            <li
              key={board.id}
              className="flex flex-col gap-3 py-4 sm:flex-row sm:items-center sm:justify-between"
            >
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
              </div>
              <Button
                variant="primary"
                size="sm"
                disabled={busyId !== null}
                onClick={() => restore(board)}
              >
                {busyId === board.id ? "Restaurando…" : "Restaurar tablero"}
              </Button>
            </li>
          ))}
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
