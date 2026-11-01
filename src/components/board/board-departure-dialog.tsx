"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";
import { submitBoardDeparture } from "@/lib/board-departure-actions";
import {
  type BoardDepartureCommand,
  type BoardDepartureFlow,
  cancelBoardDeparture,
  confirmBoardDeparture,
  createBoardDepartureCommand,
  createBoardDepartureFlow,
  createBoardDepartureSubmissionGate,
  getBoardDepartureResultEffect,
  getExpiredUnknownBoardDeparture,
  rememberExpiredUnknownBoardDeparture,
  selectBoardDepartureSuccessor,
} from "@/lib/board-departure-flow";
import type { AssignableBoardMember } from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface BoardDepartureDialogProps {
  open: boolean;
  onClose: () => void;
  slug: string;
  boardId: string;
  actorId: string;
  memberRole: "owner" | "collaborator";
  hasOtherCurrentMembers: boolean | null;
  eligibleSuccessors: AssignableBoardMember[] | null;
}

function blockedMessage(
  reason:
    | "membership_status_unavailable"
    | "successor_list_unavailable"
    | "no_eligible_successor",
) {
  switch (reason) {
    case "membership_status_unavailable":
      return "No pudimos verificar si queda otra persona en el tablero. Actualiza la página antes de continuar.";
    case "successor_list_unavailable":
      return "No pudimos verificar quién puede recibir la propiedad. Actualiza la página antes de continuar.";
    case "no_eligible_successor":
      return "Hay otros miembros activos, pero ninguno puede recibir la propiedad ahora. Elige a un sucesor habilitado cuando esté disponible.";
  }
}

export function BoardDepartureDialog({
  open,
  onClose,
  slug,
  boardId,
  actorId,
  memberRole,
  hasOtherCurrentMembers,
  eligibleSuccessors,
}: BoardDepartureDialogProps) {
  const router = useRouter();
  const [flow, setFlow] = useState<BoardDepartureFlow>({ status: "closed" });
  const [error, setError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [canRetry, setCanRetry] = useState(true);
  const [requiresExit, setRequiresExit] = useState(false);
  const [pendingCommand, setPendingCommand] =
    useState<BoardDepartureCommand | null>(null);
  const pendingCommandRef = useRef<BoardDepartureCommand | null>(null);
  const isSubmittingRef = useRef(false);
  const submissionGateRef = useRef(createBoardDepartureSubmissionGate());
  useEffect(() => {
    if (!open) return;
    setFlow(
      createBoardDepartureFlow({
        role: memberRole,
        actorId,
        hasOtherCurrentMembers,
        eligibleSuccessors,
      }),
    );
    setError(null);
    setCanRetry(true);
    setRequiresExit(false);
    pendingCommandRef.current = null;
    setPendingCommand(null);
  }, [actorId, eligibleSuccessors, hasOtherCurrentMembers, memberRole, open]);

  function closeDialog() {
    if (isSubmittingRef.current || pendingCommandRef.current) return;
    setFlow((current) => cancelBoardDeparture(current));
    setError(null);
    onClose();
  }

  function chooseSuccessor(successorUserId: string) {
    if (pendingCommandRef.current) return;
    setFlow((current) =>
      selectBoardDepartureSuccessor(current, successorUserId),
    );
    setError(null);
  }

  async function sendCommand(command: BoardDepartureCommand) {
    return submissionGateRef.current(() => submitBoardDeparture(slug, command));
  }

  async function confirmDeparture() {
    if (isSubmittingRef.current || !canRetry) return;
    if (!pendingCommandRef.current) {
      const previewCommand = createBoardDepartureCommand(
        flow,
        boardId,
        "00000000-0000-4000-8000-000000000000",
      );
      if (
        previewCommand &&
        getExpiredUnknownBoardDeparture(actorId, previewCommand)
      ) {
        setCanRetry(false);
        setRequiresExit(true);
        setError(
          "Hay una salida anterior que venció sin confirmación recuperable. Conservamos su operación y no generaremos otra clave en este tablero.",
        );
        return;
      }
    }
    const command =
      pendingCommandRef.current ??
      createBoardDepartureCommand(flow, boardId, generateUUID());
    if (!command) return;

    if (!pendingCommandRef.current) {
      pendingCommandRef.current = command;
      setPendingCommand(command);
    }
    isSubmittingRef.current = true;
    setIsSubmitting(true);
    setError(null);

    const result = await confirmBoardDeparture(
      flow,
      boardId,
      command.operation_id,
      () => sendCommand(command),
    );
    isSubmittingRef.current = false;
    setIsSubmitting(false);
    if (result.status === "already_submitting") return;
    if (result.status === "not_ready") return;

    switch (getBoardDepartureResultEffect(result.status)) {
      case "leave_context":
        pendingCommandRef.current = null;
        setPendingCommand(null);
        setFlow({ status: "closed" });
        onClose();
        router.replace("/");
        return;
      case "refresh_review":
        pendingCommandRef.current = null;
        setPendingCommand(null);
        setError(
          flow.status === "review" && flow.action === "transfer"
            ? "La elegibilidad cambió antes de confirmar. Actualizamos las opciones; vuelve a elegir explícitamente a la persona sucesora."
            : "El estado del tablero cambió antes de confirmar. Actualiza las opciones y revisa la salida.",
        );
        router.refresh();
        return;
      case "show_rejection":
        pendingCommandRef.current = null;
        setPendingCommand(null);
        setCanRetry(false);
        setError(
          "message" in result
            ? result.message
            : "La confirmación necesita una revisión antes de continuar.",
        );
        router.refresh();
        return;
      case "block_expired_intent":
        rememberExpiredUnknownBoardDeparture(actorId, command);
        pendingCommandRef.current = null;
        setPendingCommand(null);
        setCanRetry(false);
        setRequiresExit(true);
        setError(
          "Venció el plazo para reconciliar esta confirmación. Conservamos la operación y no generaremos otra clave en este tablero; vuelve a la lista para verificar tu acceso.",
        );
        return;
      case "retry_same_command":
        setError(
          "No se pudo confirmar la salida. Reintenta esta misma confirmación para reconciliarla sin repetir el cambio.",
        );
        return;
      case "ignore":
        return;
    }
  }

  const isBlocked = flow.status === "blocked";
  const isTransfer = flow.status === "review" && flow.action === "transfer";
  const isLastMember =
    flow.status === "review" && flow.action === "delete_last_member";
  const isReadyToConfirm =
    flow.status === "review" &&
    (flow.action !== "transfer" || Boolean(flow.successor_user_id));

  return (
    <Modal
      open={open}
      onClose={closeDialog}
      title={
        isLastMember
          ? "Salir y poner el tablero en recuperación"
          : isTransfer
            ? "Transferir la propiedad y salir"
            : "Salir del tablero"
      }
      closeLabel="Cerrar salida del tablero"
    >
      <div className="flex flex-col gap-4">
        {flow.status === "blocked" ? (
          <output className="text-sm text-text-secondary">
            {blockedMessage(flow.reason)}
          </output>
        ) : isLastMember ? (
          <div className="flex flex-col gap-3 text-sm text-text-secondary">
            <p>
              No queda otra persona miembro activa. Si confirmas, se conservarán
              los datos del tablero durante 7 días y se cerrará tu acceso. Para
              restaurarlo hará falta elegir un nuevo propietario.
            </p>
            <p>
              Esta acción es distinta de salir del tablero y no se ejecuta al
              cerrar esta ventana.
            </p>
          </div>
        ) : isTransfer ? (
          <div className="flex flex-col gap-3">
            <p className="text-sm text-text-secondary">
              Elige a una persona miembro habilitada. La propiedad y tu salida
              se confirman en una sola operación; la elegibilidad se volverá a
              comprobar al confirmar.
            </p>
            <label
              htmlFor="board-departure-successor"
              className="font-medium text-sm text-text-primary"
            >
              Nuevo propietario
            </label>
            <select
              id="board-departure-successor"
              value={
                flow.status === "review" ? (flow.successor_user_id ?? "") : ""
              }
              onChange={(event) => chooseSuccessor(event.target.value)}
              disabled={Boolean(pendingCommand) || isSubmitting}
              className="h-11 w-full rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent focus:ring-1 focus:ring-accent disabled:opacity-60"
            >
              <option value="">Elige un miembro habilitado</option>
              {flow.status === "review" &&
                flow.eligibleSuccessors.map((member) => (
                  <option key={member.user_id} value={member.user_id}>
                    {member.name} · {member.email}
                  </option>
                ))}
            </select>
            <p className="text-text-muted text-xs">
              No se cambiará el sucesor automáticamente si su elegibilidad
              cambia.
            </p>
          </div>
        ) : (
          <p className="text-sm text-text-secondary">
            Al salir, tus tareas y comentarios conservarán su autoría. Se
            quitarán tus asignaciones pendientes y las menciones a tu cuenta
            quedarán como texto sin identidad.
          </p>
        )}

        {error ? (
          <p className="text-red-300 text-sm" role="alert">
            {error}
          </p>
        ) : null}

        {isBlocked ? (
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={closeDialog}>
              Volver al tablero
            </Button>
            <Button
              variant="primary"
              onClick={() => router.refresh()}
              disabled={isSubmitting}
            >
              Actualizar opciones
            </Button>
          </div>
        ) : (
          <div className="flex items-center justify-end gap-2">
            <Button
              variant="ghost"
              onClick={closeDialog}
              disabled={isSubmitting || Boolean(pendingCommand)}
            >
              Cancelar
            </Button>
            {requiresExit ? (
              <Button
                variant="primary"
                onClick={() => {
                  onClose();
                  router.replace("/");
                }}
              >
                Ir a tableros
              </Button>
            ) : null}
            <Button
              variant="danger"
              onClick={() => void confirmDeparture()}
              disabled={!isReadyToConfirm || isSubmitting || !canRetry}
            >
              {isSubmitting
                ? "Confirmando…"
                : pendingCommand
                  ? "Reintentar confirmación"
                  : isLastMember
                    ? "Confirmar recuperación"
                    : "Confirmar salida"}
            </Button>
          </div>
        )}
      </div>
    </Modal>
  );
}
