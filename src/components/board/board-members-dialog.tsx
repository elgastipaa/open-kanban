"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";
import { removeBoardCollaborator } from "@/lib/board-member-removal-actions";
import {
  type BoardMemberRemovalCommand,
  type BoardMemberRemovalFlow,
  cancelBoardMemberRemoval,
  clearExpiredUnknownBoardMemberRemoval,
  confirmBoardMemberRemoval,
  createBoardMemberRemovalCommand,
  createBoardMemberRemovalFlow,
  createBoardMemberRemovalSubmissionGate,
  finishBoardMemberRemoval,
  getExpiredUnknownBoardMemberRemoval,
  rememberExpiredUnknownBoardMemberRemoval,
  requestBoardMemberRemoval,
  retryBoardMemberRemoval,
  startBoardMemberRemoval,
} from "@/lib/board-member-removal-flow";
import type { CurrentBoardMember } from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface BoardMembersDialogProps {
  open: boolean;
  onClose: () => void;
  slug: string;
  boardId: string;
  actorId: string;
  memberRole: "owner" | "collaborator";
  members: CurrentBoardMember[] | null;
}

export function BoardMembersDialog({
  open,
  onClose,
  slug,
  boardId,
  actorId,
  memberRole,
  members,
}: BoardMembersDialogProps) {
  const router = useRouter();
  const [flow, setFlow] = useState(createBoardMemberRemovalFlow);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [expiredCommand, setExpiredCommand] =
    useState<BoardMemberRemovalCommand | null>(null);
  const isSubmittingRef = useRef(false);
  const submissionGateRef = useRef(createBoardMemberRemovalSubmissionGate());

  useEffect(() => {
    if (
      !expiredCommand ||
      !members ||
      members.some(
        (member) => member.membership_id === expiredCommand.membership_id,
      )
    ) {
      return;
    }
    clearExpiredUnknownBoardMemberRemoval(
      actorId,
      boardId,
      expiredCommand.membership_id,
    );
    setExpiredCommand(null);
    setFlow({
      status: "roster",
      message: "El colaborador ya no figura como miembro actual del tablero.",
    });
  }, [actorId, boardId, expiredCommand, members]);

  function closeDialog() {
    if (isSubmittingRef.current) return;
    setFlow((current) => cancelBoardMemberRemoval(current));
    onClose();
  }

  function requestRemoval(member: CurrentBoardMember) {
    setFlow((current) =>
      requestBoardMemberRemoval(current, memberRole, member),
    );
  }

  async function submitRemoval(
    submittingFlow: Extract<BoardMemberRemovalFlow, { status: "submitting" }>,
    confirmationFlow?: BoardMemberRemovalFlow,
  ) {
    if (submittingFlow.status !== "submitting" || isSubmittingRef.current) {
      return;
    }
    isSubmittingRef.current = true;
    setIsSubmitting(true);

    let result: Awaited<ReturnType<typeof removeBoardCollaborator>>;
    try {
      const submission =
        confirmationFlow?.status === "confirming"
          ? await confirmBoardMemberRemoval(
              confirmationFlow,
              boardId,
              submittingFlow.command.operation_id,
              (command) =>
                submissionGateRef.current(() =>
                  removeBoardCollaborator(slug, command),
                ),
            )
          : await submissionGateRef.current(() =>
              removeBoardCollaborator(slug, submittingFlow.command),
            );
      if (submission.status === "already_submitting") return;
      if (submission.status === "not_ready") {
        setFlow({
          status: "roster",
          error: "La confirmación ya no está disponible. Actualiza la lista.",
        });
        router.refresh();
        return;
      }
      result = submission;
    } catch {
      result = { status: "retryable" };
    }
    isSubmittingRef.current = false;
    setIsSubmitting(false);
    if (result.status === "expired_unknown") {
      rememberExpiredUnknownBoardMemberRemoval(actorId, submittingFlow.command);
      setExpiredCommand(submittingFlow.command);
    }

    setFlow(finishBoardMemberRemoval(submittingFlow, result.status));
    if (result.status !== "retryable") router.refresh();
  }

  async function confirmRemoval() {
    if (isSubmittingRef.current) return;
    if (flow.status === "retryable") {
      const submitting = retryBoardMemberRemoval(flow);
      if (submitting.status === "submitting") await submitRemoval(submitting);
      return;
    }
    const command = createBoardMemberRemovalCommand(
      flow,
      boardId,
      generateUUID(),
    );
    if (!command) return;
    const submitting = startBoardMemberRemoval(flow, command);
    if (submitting.status === "submitting") {
      await submitRemoval(submitting, flow);
    }
  }

  const confirmingMember =
    flow.status === "confirming" ||
    flow.status === "submitting" ||
    flow.status === "retryable"
      ? flow.member
      : null;
  const isRetryable = flow.status === "retryable";
  const error =
    flow.status === "roster" || flow.status === "retryable"
      ? flow.error
      : undefined;
  const message = flow.status === "roster" ? flow.message : undefined;

  return (
    <Modal
      open={open}
      onClose={closeDialog}
      title={
        confirmingMember
          ? `Retirar acceso de ${confirmingMember.name}`
          : "Miembros del tablero"
      }
      closeLabel="Cerrar miembros del tablero"
    >
      {confirmingMember ? (
        <div className="flex flex-col gap-4">
          <p className="text-sm text-text-secondary leading-relaxed">
            {isRetryable
              ? flow.error
              : `La persona ${confirmingMember.name} dejará de acceder a este tablero. Sus tareas y autoría se conservarán; se desasignarán sus tareas pendientes, sus menciones históricas quedarán como texto y se revocarán sus invitaciones pendientes.`}
          </p>
          <div className="flex items-center justify-end gap-2">
            <Button
              variant="ghost"
              onClick={closeDialog}
              disabled={isSubmitting}
            >
              {isRetryable ? "Cerrar" : "Cancelar"}
            </Button>
            <Button
              variant="danger"
              onClick={() => void confirmRemoval()}
              disabled={isSubmitting}
            >
              {isSubmitting
                ? "Retirando…"
                : isRetryable
                  ? "Reintentar la misma operación"
                  : "Retirar colaborador"}
            </Button>
          </div>
        </div>
      ) : (
        <div className="flex flex-col gap-4">
          {error ? (
            <p className="text-red-300 text-sm" role="alert">
              {error}
            </p>
          ) : null}
          {expiredCommand ? (
            <div className="flex items-center justify-between gap-3 rounded-md border border-amber-700/50 bg-amber-950/20 px-3 py-2">
              <output className="text-amber-200 text-sm">
                No generaremos otra operación para esta membresía hasta
                reconciliar su estado.
              </output>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => router.refresh()}
              >
                Actualizar lista
              </Button>
            </div>
          ) : null}
          {message ? (
            <output className="text-green-300 text-sm">{message}</output>
          ) : null}
          {members === null ? (
            <output className="text-sm text-text-secondary">
              No pudimos cargar los miembros. Actualiza la página para volver a
              intentarlo.
            </output>
          ) : members.length === 0 ? (
            <p className="text-sm text-text-secondary">
              No hay miembros actuales para mostrar.
            </p>
          ) : (
            <ul
              aria-label="Miembros actuales del tablero"
              className="space-y-2"
            >
              {members.map((member) => (
                <li
                  key={member.membership_id}
                  className="flex items-center justify-between gap-3 rounded-md border border-border bg-surface-base px-3 py-2"
                >
                  <div className="min-w-0">
                    <p className="truncate text-sm text-text-primary">
                      {member.name}
                    </p>
                    <p className="text-text-muted text-xs">
                      {member.role === "owner" ? "Propietario" : "Colaborador"}
                    </p>
                  </div>
                  {memberRole === "owner" &&
                  member.role === "collaborator" &&
                  !getExpiredUnknownBoardMemberRemoval(
                    actorId,
                    boardId,
                    member.membership_id,
                  ) ? (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => requestRemoval(member)}
                      aria-label={`Retirar a ${member.name} del tablero`}
                    >
                      Retirar
                    </Button>
                  ) : memberRole === "owner" &&
                    member.role === "collaborator" ? (
                    <span className="text-amber-200 text-xs">
                      Retiro pendiente de reconciliar
                    </span>
                  ) : null}
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </Modal>
  );
}
