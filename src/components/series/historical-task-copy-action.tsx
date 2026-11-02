"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Modal } from "@/components/ui/modal";
import {
  copyHistoricalTask,
  type HistoricalTaskCopyPreview,
} from "@/lib/db/repetition-series";
import { createClient } from "@/lib/supabase/client";
import type { Column } from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface HistoricalTaskCopyActionProps {
  slug: string;
  preview: HistoricalTaskCopyPreview;
  columns: Pick<Column, "id" | "title">[];
}

export function HistoricalTaskCopyAction({
  slug,
  preview,
  columns,
}: HistoricalTaskCopyActionProps) {
  const router = useRouter();
  const [isOpen, setIsOpen] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [currentPreview, setCurrentPreview] = useState(preview);
  const [title, setTitle] = useState(preview.title ?? "");
  const [targetColumnId, setTargetColumnId] = useState(
    preview.target_column_id ?? columns[0]?.id ?? "",
  );
  const [operationId, setOperationId] = useState("");
  const [notice, setNotice] = useState("");

  if (
    preview.status !== "available" ||
    !preview.source_task_id ||
    !preview.source_hash ||
    columns.length === 0
  ) {
    return null;
  }

  function openCopy() {
    setCurrentPreview(preview);
    setTitle(preview.title ?? "");
    setTargetColumnId(preview.target_column_id ?? columns[0]?.id ?? "");
    setOperationId(generateUUID());
    setNotice("");
    setIsOpen(true);
  }

  async function confirmCopy() {
    if (!currentPreview.source_task_id || !currentPreview.source_hash) return;
    setIsSaving(true);
    setNotice("");
    try {
      const result = await copyHistoricalTask(createClient(), {
        operationId: operationId || generateUUID(),
        slug,
        sourceTaskId: currentPreview.source_task_id,
        targetColumnId,
        title,
        expectedSourceHash: currentPreview.source_hash,
      });
      if (result.status === "source_changed") {
        setCurrentPreview({
          ...currentPreview,
          ...result,
          status: "available",
          source_task_id: currentPreview.source_task_id,
          target_column_id: result.target_column_id ?? targetColumnId,
        });
        setNotice(
          "El contenido copiable cambió. Revisa la vista previa actualizada y confirma otra vez; conservamos el título y el destino elegidos.",
        );
        return;
      }
      if (result.status !== "confirmed" || !result.task) {
        setNotice(
          "La copia no se creó. Comprueba que la ocurrencia siga disponible y vuelve a revisar el origen.",
        );
        return;
      }
      setIsOpen(false);
      router.push(`/${slug}?task=${encodeURIComponent(result.task.id)}`);
    } catch {
      setNotice(
        "No se pudo confirmar la copia. Revisa el tablero antes de volver a intentarlo.",
      );
    } finally {
      setIsSaving(false);
    }
  }

  const steps = currentPreview.steps ?? [];
  const priorityLabel = {
    low: "Baja",
    medium: "Media",
    high: "Alta",
    urgent: "Urgente",
  }[currentPreview.priority ?? "medium"];

  return (
    <>
      <Button variant="ghost" onClick={openCopy}>
        Copiar como tarea puntual
      </Button>
      <Modal
        open={isOpen}
        onClose={() => setIsOpen(false)}
        title="Copiar ocurrencia como tarea puntual"
        fullScreenMobile
      >
        <div className="flex flex-col gap-4">
          <p className="text-sm text-text-secondary leading-6">
            La copia tendrá identidad nueva y quedará pendiente. El origen
            seguirá intacto. Se copian título, descripción, prioridad y pasos
            sin marcar; no se copian responsable, fecha límite, repetición,
            conversación ni archivos.
          </p>
          <Input
            id="historical-copy-title"
            label="Título"
            value={title}
            maxLength={200}
            required
            disabled={isSaving}
            onChange={(event) => setTitle(event.target.value)}
          />
          <div className="flex flex-col gap-1.5">
            <label
              htmlFor="historical-copy-column"
              className="font-medium text-text-secondary text-xs"
            >
              Columna de destino
            </label>
            <select
              id="historical-copy-column"
              value={targetColumnId}
              disabled={isSaving}
              onChange={(event) => setTargetColumnId(event.target.value)}
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
              {title || "Sin título"}
            </p>
            {currentPreview.description ? (
              <p className="mt-2 whitespace-pre-wrap text-text-secondary">
                {currentPreview.description}
              </p>
            ) : null}
            <p className="mt-2 text-text-muted">
              Prioridad: {priorityLabel} · {steps.length} pasos, todos sin
              marcar
            </p>
            {steps.length ? (
              <ul className="mt-2 list-inside list-disc text-text-secondary">
                {steps.map((step, index) => (
                  <li key={`${step.position}-${index}`}>{step.text}</li>
                ))}
              </ul>
            ) : null}
          </section>
          {notice ? (
            <output className="text-sm text-text-secondary" aria-live="polite">
              {notice}
            </output>
          ) : null}
          <div className="flex flex-wrap justify-end gap-2">
            <Button
              variant="ghost"
              onClick={() => setIsOpen(false)}
              disabled={isSaving}
            >
              Cancelar
            </Button>
            <Button
              variant="primary"
              onClick={() => void confirmCopy()}
              disabled={isSaving || !title.trim() || !targetColumnId}
            >
              {isSaving ? "Creando copia…" : "Crear copia"}
            </Button>
          </div>
        </div>
      </Modal>
    </>
  );
}
