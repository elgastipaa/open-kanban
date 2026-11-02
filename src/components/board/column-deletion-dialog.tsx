"use client";

import { useEffect, useId, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";
import type { ColumnDeletionCommand } from "@/lib/column-deletion-flow";
import {
  type ColumnDeletionDialogState,
  type ColumnDeletionResultStatus,
  closeColumnDeletionDialog,
  columnDeletionErrorMessage,
  columnDeletionNoDestinationMessage,
  failColumnDeletionPreview,
  failColumnDeletionSubmission,
  getColumnDeletionCommand,
  resolveColumnDeletionPreview,
  selectColumnDeletionDestination,
  startColumnDeletionPreview,
  startColumnDeletionSubmission,
} from "@/lib/column-deletion-flow";
import {
  type ColumnDeletionPreview,
  ColumnRecoveryError,
  type ColumnRecoveryResult,
  previewDeleteColumn,
} from "@/lib/db/columns";
import { createClient } from "@/lib/supabase/client";
import { generateUUID } from "@/lib/utils";

interface ColumnDeletionDialogProps {
  open: boolean;
  slug: string;
  columnId: string | null;
  onClose: () => void;
  onDeleted: (result: ColumnRecoveryResult) => void;
  onDelete: (command: ColumnDeletionCommand) => Promise<ColumnRecoveryResult>;
}

const INITIAL_STATE: ColumnDeletionDialogState = { status: "closed" };

function submissionError(
  error: unknown,
): Exclude<ColumnDeletionResultStatus, "confirmed"> {
  if (error instanceof ColumnRecoveryError) {
    return error.reason === "uncertain" ? "uncertain" : "unavailable";
  }
  return "uncertain";
}

function retryNeedsNewPreview(
  status: Exclude<ColumnDeletionResultStatus, "confirmed">,
): boolean {
  return status !== "retryable" && status !== "uncertain";
}

export function ColumnDeletionDialog({
  open,
  slug,
  columnId,
  onClose,
  onDeleted,
  onDelete,
}: ColumnDeletionDialogProps) {
  const [state, setState] = useState<ColumnDeletionDialogState>(INITIAL_STATE);
  const [previewGeneration, setPreviewGeneration] = useState(0);
  const operationIdRef = useRef<string | null>(null);
  const destinationId = useId();
  const alertId = useId();

  useEffect(() => {
    if (!open || !columnId) {
      setState(closeColumnDeletionDialog());
      operationIdRef.current = null;
      return;
    }

    let active = true;
    const loading = startColumnDeletionPreview(columnId, previewGeneration);
    setState(loading);
    operationIdRef.current = null;
    void previewDeleteColumn(createClient(), slug, columnId)
      .then((preview: ColumnDeletionPreview) => {
        if (active)
          setState((current) =>
            resolveColumnDeletionPreview(current, preview, previewGeneration),
          );
      })
      .catch(() => {
        if (active)
          setState((current) =>
            failColumnDeletionPreview(current, previewGeneration),
          );
      });

    return () => {
      active = false;
    };
  }, [columnId, open, previewGeneration, slug]);

  const canClose = state.status !== "submitting";

  function close() {
    if (!canClose) return;
    setState(closeColumnDeletionDialog());
    operationIdRef.current = null;
    onClose();
  }

  async function confirm() {
    if (state.status === "submitting") return;
    const operationId = operationIdRef.current ?? generateUUID();
    const submission = startColumnDeletionSubmission(state, operationId);
    if (!submission.command) return;
    operationIdRef.current = submission.command.operation_id;
    setState(submission.state);

    try {
      const result = await onDelete(submission.command);
      if (result.status === "confirmed") {
        operationIdRef.current = null;
        setState(closeColumnDeletionDialog());
        onDeleted(result);
        onClose();
        return;
      }
      const next = failColumnDeletionSubmission(
        submission.state,
        result.status,
      );
      setState(next);
      if (retryNeedsNewPreview(result.status)) operationIdRef.current = null;
    } catch (error) {
      setState(
        failColumnDeletionSubmission(submission.state, submissionError(error)),
      );
    }
  }

  function refreshPreview() {
    if (state.status === "submitting") return;
    operationIdRef.current = null;
    setPreviewGeneration((generation) => generation + 1);
  }

  const command = getColumnDeletionCommand(
    state,
    operationIdRef.current ?? "preview-only",
  );
  const hasSubmitError = state.status === "submit_error";
  const submitError = hasSubmitError ? state.error : null;
  const canRetrySameCommand =
    state.status === "submit_error" && !retryNeedsNewPreview(state.error);
  const noDeletionDestination =
    (state.status === "ready" ||
      state.status === "submitting" ||
      state.status === "submit_error") &&
    state.preview.destinations.length === 0;

  return (
    <Modal
      open={open}
      onClose={close}
      title="Eliminar columna"
      closeLabel="Cerrar confirmación de columna"
      fullScreenMobile
    >
      <div
        className="space-y-4"
        aria-busy={state.status === "loading" || state.status === "submitting"}
      >
        {state.status === "loading" ? (
          <output
            className="flex min-h-24 items-center justify-center gap-3 text-sm text-text-secondary"
            aria-live="polite"
          >
            <span className="board-spinner" aria-hidden="true" />
            Cargando vista previa…
          </output>
        ) : null}

        {state.status === "preview_error" ? (
          <div className="space-y-3" role="alert">
            <p className="text-sm text-text-secondary">
              No se pudo cargar la vista previa. Actualiza el tablero e
              inténtalo otra vez.
            </p>
            <Button variant="ghost" onClick={refreshPreview}>
              Reintentar vista previa
            </Button>
          </div>
        ) : null}

        {state.status === "ready" ||
        state.status === "submitting" ||
        state.status === "submit_error" ? (
          <>
            {noDeletionDestination ? (
              <output
                className="text-sm text-text-secondary leading-relaxed"
                aria-live="polite"
              >
                {columnDeletionNoDestinationMessage(state.preview.task_count)}
              </output>
            ) : (
              <>
                <p className="text-sm text-text-secondary leading-relaxed">
                  {state.preview.task_count === 0
                    ? `La columna “${state.preview.column_title}” está vacía.`
                    : `La columna “${state.preview.column_title}” tiene ${state.preview.task_count} ${state.preview.task_count === 1 ? "tarea" : "tareas"}. Elige dónde trasladarlas antes de eliminarla.`}{" "}
                  Podrás recuperar su estructura durante siete días; los
                  traslados no se deshacen.
                </p>

                {state.preview.task_count > 0 ? (
                  <div className="space-y-2">
                    <label
                      htmlFor={destinationId}
                      className="block font-medium text-sm text-text-primary"
                    >
                      Trasladar las tareas a
                    </label>
                    <select
                      id={destinationId}
                      value={
                        state.status === "ready"
                          ? (state.destination_column_id ?? "")
                          : (state.command.destination_column_id ?? "")
                      }
                      onChange={(event) =>
                        setState((current) =>
                          selectColumnDeletionDestination(
                            current,
                            event.target.value || null,
                          ),
                        )
                      }
                      disabled={state.status !== "ready"}
                      aria-describedby={alertId}
                      className="w-full rounded-md border border-border bg-surface-raised px-3 py-2 text-sm text-text-primary outline-none focus:border-accent"
                    >
                      <option value="">Elige una columna del tablero</option>
                      {state.preview.destinations.map((destination) => (
                        <option key={destination.id} value={destination.id}>
                          {destination.title}
                        </option>
                      ))}
                    </select>
                    <span id={alertId} className="sr-only">
                      Solo se muestran columnas de este tablero.
                    </span>
                  </div>
                ) : null}

                {submitError ? (
                  <p className="text-priority-urgent text-sm" role="alert">
                    {columnDeletionErrorMessage(submitError)}
                  </p>
                ) : null}
              </>
            )}

            <div className="flex flex-wrap items-center justify-end gap-2 pt-2">
              <Button variant="ghost" onClick={close} disabled={!canClose}>
                Cancelar
              </Button>
              {!noDeletionDestination &&
              submitError &&
              retryNeedsNewPreview(submitError) ? (
                <Button variant="ghost" onClick={refreshPreview}>
                  Revisar vista previa
                </Button>
              ) : null}
              {!noDeletionDestination ? (
                <Button
                  variant="danger"
                  onClick={() => void confirm()}
                  disabled={
                    state.status === "submitting" ||
                    (state.status === "ready" && !command) ||
                    (state.status === "submit_error" && !canRetrySameCommand)
                  }
                >
                  {state.status === "submitting"
                    ? "Eliminando…"
                    : canRetrySameCommand
                      ? "Reintentar operación"
                      : "Eliminar columna"}
                </Button>
              ) : null}
            </div>
          </>
        ) : null}
      </div>
    </Modal>
  );
}
