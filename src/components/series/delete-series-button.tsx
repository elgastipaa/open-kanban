"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import {
  deleteRepetitionSeries,
  previewDeleteRepetitionSeries,
  type RepetitionSeriesDeletionPreview,
} from "@/lib/db/repetition-series";
import {
  createRepetitionSeriesDeletionCommand,
  getRepetitionSeriesDeletionConfirmation,
} from "@/lib/repetition-series-recovery-state";
import { createClient } from "@/lib/supabase/client";
import { generateUUID } from "@/lib/utils";

interface DeleteSeriesButtonProps {
  slug: string;
  boardId: string;
  seriesId: string;
  returnState: "active" | "stopped" | "finished" | null;
}

export function DeleteSeriesButton({
  slug,
  boardId,
  seriesId,
  returnState,
}: DeleteSeriesButtonProps) {
  const router = useRouter();
  const [isOpen, setIsOpen] = useState(false);
  const [isPreviewing, setIsPreviewing] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [preview, setPreview] =
    useState<RepetitionSeriesDeletionPreview | null>(null);
  const [pendingOperationId, setPendingOperationId] = useState<string | null>(
    null,
  );
  const [notice, setNotice] = useState("");

  async function prepareDeletion() {
    setIsPreviewing(true);
    setNotice("");
    setPreview(null);
    setPendingOperationId(null);
    try {
      const result = await previewDeleteRepetitionSeries(
        createClient(),
        slug,
        seriesId,
      );
      if (result.status !== "available") {
        setNotice(
          "La serie ya no está disponible con tu acceso actual. Actualiza la página.",
        );
        router.refresh();
        return;
      }
      setPreview(result);
      setIsOpen(true);
    } catch {
      setNotice(
        "No se pudo revisar el alcance de la serie. Actualiza la página antes de eliminarla.",
      );
    } finally {
      setIsPreviewing(false);
    }
  }

  async function confirmDeletion() {
    if (!preview) {
      setNotice("Vuelve a revisar la serie antes de confirmar.");
      return;
    }
    const command = createRepetitionSeriesDeletionCommand(preview, {
      operationId: pendingOperationId ?? generateUUID(),
      slug,
      seriesId,
      expectedRevision: preview.revision ?? -1,
    });
    if (!command) {
      setIsOpen(false);
      setNotice(
        "La serie cambió o el resumen está incompleto. Actualiza la página antes de volver a intentarlo.",
      );
      router.refresh();
      return;
    }
    if (!pendingOperationId) setPendingOperationId(command.operation_id);

    setIsSaving(true);
    setNotice("");
    try {
      const result = await deleteRepetitionSeries(createClient(), {
        operationId: command.operation_id,
        slug: command.slug,
        seriesId: command.series_id,
        expectedRevision: command.expected_revision,
        confirmHistory: command.confirm_history,
      });
      if (result.status === "confirmed") {
        setIsOpen(false);
        router.replace(
          `/series?board=${encodeURIComponent(boardId)}${returnState ? `&state=${returnState}` : ""}`,
        );
        router.refresh();
        return;
      }
      if (result.status === "conflict") {
        setIsOpen(false);
        setNotice(
          "La serie cambió mientras la revisabas. Actualizamos el tablero; vuelve a confirmar con el estado actual.",
        );
        router.refresh();
        return;
      }
      if (result.status === "expired_unknown") {
        setNotice(
          "No se pudo confirmar la respuesta. Puedes reintentar con la misma operación o actualizar y revisar la papelera.",
        );
        return;
      }
      setIsOpen(false);
      setNotice(
        "La serie ya no está disponible para eliminar. Actualiza la página y revisa el estado.",
      );
      router.refresh();
    } catch {
      setNotice(
        "No se pudo confirmar si la serie se eliminó. Reintenta con esta misma confirmación o actualiza la página y revisa la papelera.",
      );
    } finally {
      setIsSaving(false);
    }
  }

  return (
    <div className="flex flex-col items-start gap-2">
      <Button
        type="button"
        variant="danger"
        onClick={() => void prepareDeletion()}
        disabled={isPreviewing || isSaving}
      >
        {isPreviewing ? "Revisando serie…" : "Eliminar serie completa"}
      </Button>
      {notice ? (
        <output
          className="max-w-md text-sm text-text-secondary"
          aria-live="polite"
        >
          {notice}
        </output>
      ) : null}
      <ConfirmDialog
        open={isOpen}
        onClose={() => {
          if (isSaving) return;
          setIsOpen(false);
          setPendingOperationId(null);
        }}
        onConfirm={() => void confirmDeletion()}
        title="Eliminar toda la serie"
        description={
          preview
            ? getRepetitionSeriesDeletionConfirmation(preview)
            : "Vuelve a revisar el alcance antes de eliminar la serie."
        }
        confirmLabel="Eliminar serie completa"
        cancelLabel="Conservar serie"
        loading={isSaving}
      />
    </div>
  );
}
