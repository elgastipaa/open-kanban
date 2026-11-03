"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Modal } from "@/components/ui/modal";
import {
  copyTask,
  previewTaskCopy,
  type TaskCopyCommand,
  type TaskCopyPreview,
} from "@/lib/db/task-copy";
import { createClient } from "@/lib/supabase/client";
import {
  acknowledgeTaskCopyPreview,
  canCreateTaskCopy,
  emptyTaskCopyFormState,
  receiveTaskCopyPreview,
  type TaskCopyFormState,
} from "@/lib/task-copy-state";
import type { Column } from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface TaskCopyActionProps {
  slug: string;
  sourceTaskId: string;
  columns: Pick<Column, "id" | "title">[];
  disabled?: boolean;
  triggerLabel?: string;
  triggerSize?: "sm" | "md";
}

export function TaskCopyAction({
  slug,
  sourceTaskId,
  columns,
  disabled = false,
  triggerLabel = "Copiar como tarea puntual",
  triggerSize = "md",
}: TaskCopyActionProps) {
  const router = useRouter();
  const [isOpen, setIsOpen] = useState(false);
  const [isLoadingPreview, setIsLoadingPreview] = useState(false);
  const [previewError, setPreviewError] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [isBlocked, setIsBlocked] = useState(false);
  const [isRetryable, setIsRetryable] = useState(false);
  const [isExpiredUnknown, setIsExpiredUnknown] = useState(false);
  const [form, setForm] = useState<TaskCopyFormState>(emptyTaskCopyFormState);
  const [operationId, setOperationId] = useState<string | null>(null);
  const [pendingCommand, setPendingCommand] = useState<TaskCopyCommand | null>(
    null,
  );
  const [confirmedTaskId, setConfirmedTaskId] = useState<string | null>(null);
  const [notice, setNotice] = useState("");

  async function loadPreview() {
    setIsLoadingPreview(true);
    setPreviewError(false);
    setIsBlocked(false);
    setNotice("");
    try {
      const preview = await previewTaskCopy(createClient(), slug, sourceTaskId);
      if (preview.status !== "available" || !preview.source_hash) {
        setForm(emptyTaskCopyFormState());
        setIsBlocked(true);
        setNotice(
          "El origen ya no está disponible o tu acceso cambió. No se creó ninguna copia.",
        );
        return;
      }
      setForm(receiveTaskCopyPreview(emptyTaskCopyFormState(), preview));
    } catch {
      setPreviewError(true);
      setNotice(
        "No se pudo actualizar la vista previa. Puedes volver a intentarlo.",
      );
    } finally {
      setIsLoadingPreview(false);
    }
  }

  function openCopy() {
    setIsOpen(true);
    setNotice("");
    setPreviewError(false);
    setConfirmedTaskId(null);
    setIsBlocked(false);

    if (pendingCommand) {
      const operationExpired = isExpiredUnknown;
      setOperationId(pendingCommand.operationId);
      setForm((current) => ({
        ...current,
        title: pendingCommand.title,
        targetColumnId: pendingCommand.targetColumnId,
      }));
      setIsExpiredUnknown(operationExpired);
      setIsRetryable(!operationExpired);
      setNotice(
        operationExpired
          ? "No se pudo conciliar esta operación. Revisa el tablero antes de iniciar otra copia."
          : "El resultado anterior no se confirmó. Reintenta la misma operación para consultar y completar esa copia sin duplicarla.",
      );
      return;
    }

    setIsExpiredUnknown(false);
    setForm(emptyTaskCopyFormState());
    setOperationId(generateUUID());
    setPendingCommand(null);
    setIsRetryable(false);
    void loadPreview();
  }

  function closeCopy() {
    if (isSaving) return;
    setIsOpen(false);
  }

  function commandForCurrentForm(): TaskCopyCommand | null {
    if (!form.preview?.source_hash || !canCreateTaskCopy(form)) return null;
    const nextOperationId = operationId ?? generateUUID();
    setOperationId(nextOperationId);
    return {
      operationId: nextOperationId,
      slug,
      sourceTaskId,
      targetColumnId: form.targetColumnId,
      title: form.title,
      expectedSourceHash: form.preview.source_hash,
    };
  }

  async function submitCopy(command: TaskCopyCommand | null = null) {
    const copyCommand = command ?? commandForCurrentForm();
    if (!copyCommand || isSaving) return;

    setIsSaving(true);
    setIsRetryable(false);
    setNotice("");
    setPendingCommand(copyCommand);
    try {
      const result = await copyTask(createClient(), copyCommand);
      if (result.status === "source_changed") {
        const refreshedPreview: TaskCopyPreview = {
          ...result,
          status: "available",
          source_task_id: result.source_task_id ?? sourceTaskId,
          target_column_id:
            result.target_column_id ?? copyCommand.targetColumnId,
        };
        if (!refreshedPreview.source_hash) {
          throw new Error("La respuesta no incluyó la huella de origen.");
        }
        setForm((current) => receiveTaskCopyPreview(current, refreshedPreview));
        setPendingCommand(null);
        setNotice(
          "El contenido copiable cambió. Revisa la vista previa actualizada; conservamos el título y el destino que elegiste.",
        );
        return;
      }

      if (result.status === "unavailable") {
        setForm(emptyTaskCopyFormState());
        setPendingCommand(null);
        setIsBlocked(true);
        setNotice(
          "El origen ya no está disponible o tu acceso cambió. No se creó ninguna copia.",
        );
        return;
      }

      if (result.status === "expired_unknown") {
        setIsExpiredUnknown(true);
        setNotice(
          "No se pudo conciliar el resultado de esta operación. Revisa el tablero antes de iniciar otra copia.",
        );
        return;
      }

      const copiedTaskId = result.task?.id ?? result.task_id;
      if (result.status !== "confirmed" || !copiedTaskId) {
        throw new Error("La respuesta no confirmó una tarea copiada.");
      }
      setPendingCommand(null);
      setConfirmedTaskId(copiedTaskId);
      setNotice("La copia quedó creada como una tarea pendiente.");
    } catch {
      setIsRetryable(true);
      setNotice(
        "No se pudo confirmar el resultado. Reintenta la misma operación para comprobar si la copia ya se creó.",
      );
    } finally {
      setIsSaving(false);
    }
  }

  function retryCopy() {
    if (!pendingCommand) return;
    void submitCopy(pendingCommand);
  }

  function reviewUpdatedPreview() {
    setForm((current) => acknowledgeTaskCopyPreview(current));
    setNotice("Vista previa revisada. Confirma cuando quieras crear la copia.");
  }

  function openCopiedTask() {
    if (!confirmedTaskId) return;
    setIsOpen(false);
    router.push(`/${slug}?task=${encodeURIComponent(confirmedTaskId)}`);
  }

  function reviewBoardAfterUncertainCopy() {
    setIsOpen(false);
    router.push(`/${slug}`);
  }

  if (!sourceTaskId || columns.length === 0) return null;

  const preview = form.preview;
  const steps = preview?.steps ?? [];
  const labels = preview?.labels ?? [];
  const priorityLabel = {
    low: "Baja",
    medium: "Media",
    high: "Alta",
    urgent: "Urgente",
  }[preview?.priority ?? "medium"];
  const isFormDisabled = isSaving || isRetryable || isExpiredUnknown;

  return (
    <>
      <Button
        variant="ghost"
        size={triggerSize}
        onClick={openCopy}
        disabled={disabled}
      >
        {triggerLabel}
      </Button>
      <Modal
        open={isOpen}
        onClose={closeCopy}
        title="Duplicar tarea puntual"
        closeLabel="Cerrar copia de tarea"
        fullScreenMobile
      >
        {confirmedTaskId ? (
          <section className="flex flex-col gap-4">
            <p className="text-sm text-text-secondary leading-6">
              La copia quedó creada como tarea pendiente. El origen y la serie
              siguen intactos.
            </p>
            <div className="flex flex-wrap justify-end gap-2">
              <Button variant="ghost" onClick={closeCopy}>
                Volver al origen
              </Button>
              <Button variant="primary" onClick={openCopiedTask}>
                Abrir copia
              </Button>
            </div>
          </section>
        ) : (
          <div className="flex flex-col gap-4">
            <p className="text-sm text-text-secondary leading-6">
              La copia tendrá identidad nueva y quedará pendiente. Si el origen
              es una ocurrencia, la copia será puntual y no cambiará la serie.
              No se copiarán responsable, fecha límite, conversación ni
              archivos.
            </p>
            {isLoadingPreview ? (
              <output
                className="text-sm text-text-secondary"
                aria-live="polite"
              >
                Actualizando vista previa…
              </output>
            ) : null}
            {previewError ? (
              <Button
                variant="ghost"
                onClick={() => void loadPreview()}
                disabled={isLoadingPreview}
              >
                Reintentar vista previa
              </Button>
            ) : null}
            {isBlocked ? (
              <output
                className="text-sm text-text-secondary"
                aria-live="polite"
              >
                El contenido del origen ya no está disponible para esta copia.
              </output>
            ) : null}
            {isExpiredUnknown ? (
              <Button variant="ghost" onClick={reviewBoardAfterUncertainCopy}>
                Revisar el tablero
              </Button>
            ) : null}
            {preview ? (
              <>
                <Input
                  id="task-copy-title"
                  label="Título"
                  value={form.title}
                  maxLength={200}
                  required
                  disabled={isFormDisabled}
                  onChange={(event) =>
                    setForm((current) => ({
                      ...current,
                      title: event.target.value,
                    }))
                  }
                />
                <div className="flex flex-col gap-1.5">
                  <label
                    htmlFor="task-copy-column"
                    className="font-medium text-text-secondary text-xs"
                  >
                    Columna de destino
                  </label>
                  <select
                    id="task-copy-column"
                    value={form.targetColumnId}
                    disabled={isFormDisabled}
                    onChange={(event) =>
                      setForm((current) => ({
                        ...current,
                        targetColumnId: event.target.value,
                      }))
                    }
                    className="h-11 w-full rounded-md border border-border bg-surface-raised px-3 text-sm text-text-primary outline-none focus:border-accent"
                  >
                    {columns.map((column) => (
                      <option key={column.id} value={column.id}>
                        {column.title}
                      </option>
                    ))}
                  </select>
                </div>
                <section
                  aria-label="Vista previa de la copia"
                  className="rounded-lg border border-border bg-surface-raised p-4 text-sm"
                >
                  <p className="font-medium text-text-primary">
                    Nueva tarea: {form.title || "Sin título"}
                  </p>
                  <p className="mt-2 text-text-secondary">
                    Título actual del origen: {preview.title || "Sin título"}
                  </p>
                  {preview.description ? (
                    <p className="mt-2 whitespace-pre-wrap text-text-secondary">
                      {preview.description}
                    </p>
                  ) : null}
                  <p className="mt-2 text-text-muted">
                    Prioridad: {priorityLabel} · {steps.length} pasos sin marcar
                    · {labels.length} etiquetas activas
                  </p>
                  {steps.length ? (
                    <ul className="mt-2 list-inside list-disc text-text-secondary">
                      {steps.map((step, index) => (
                        <li key={`${step.position}-${index}`}>{step.text}</li>
                      ))}
                    </ul>
                  ) : null}
                  {labels.length ? (
                    <ul
                      className="mt-2 flex flex-wrap gap-2"
                      aria-label="Etiquetas copiadas"
                    >
                      {labels.map((label) => (
                        <li
                          key={label.id}
                          className="rounded-full border border-border px-2 py-0.5 text-text-secondary"
                        >
                          {label.name}
                        </li>
                      ))}
                    </ul>
                  ) : (
                    <p className="mt-2 text-text-muted">
                      No hay etiquetas activas para copiar.
                    </p>
                  )}
                </section>
              </>
            ) : null}
            {form.reviewRequired ? (
              <Button
                variant="ghost"
                onClick={reviewUpdatedPreview}
                disabled={isFormDisabled}
              >
                Revisé la vista previa actualizada
              </Button>
            ) : null}
            {isRetryable ? (
              <Button
                variant="primary"
                onClick={retryCopy}
                disabled={isSaving || !pendingCommand}
              >
                {isSaving
                  ? "Comprobando copia…"
                  : "Reintentar la misma operación"}
              </Button>
            ) : null}
            {notice ? (
              <output
                className="text-sm text-text-secondary"
                aria-live="polite"
              >
                {notice}
              </output>
            ) : null}
            <div className="flex flex-wrap justify-end gap-2">
              <Button variant="ghost" onClick={closeCopy} disabled={isSaving}>
                Cancelar
              </Button>
              <Button
                variant="primary"
                onClick={() => void submitCopy()}
                disabled={
                  isSaving ||
                  isLoadingPreview ||
                  previewError ||
                  isBlocked ||
                  isRetryable ||
                  isExpiredUnknown ||
                  !canCreateTaskCopy(form)
                }
              >
                {isSaving ? "Creando copia…" : "Crear copia"}
              </Button>
            </div>
          </div>
        )}
      </Modal>
    </>
  );
}
