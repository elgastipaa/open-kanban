"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { stopRepetitionSeries } from "@/lib/db/repetition-series";
import { createClient } from "@/lib/supabase/client";
import { generateUUID } from "@/lib/utils";

interface StopSeriesButtonProps {
  slug: string;
  seriesId: string;
  revision: number;
}

export function StopSeriesButton({
  slug,
  seriesId,
  revision,
}: StopSeriesButtonProps) {
  const router = useRouter();
  const [isOpen, setIsOpen] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [notice, setNotice] = useState("");

  async function confirmStop() {
    setIsSaving(true);
    setNotice("");
    try {
      const result = await stopRepetitionSeries(createClient(), {
        operationId: generateUUID(),
        slug,
        seriesId,
        expectedRevision: revision,
      });
      if (
        result.status === "confirmed" ||
        result.status === "already_stopped"
      ) {
        setIsOpen(false);
        setNotice(
          "La serie quedó detenida. La tarea actual y el historial se conservaron.",
        );
        router.refresh();
        return;
      }
      if (result.status === "conflict") {
        setIsOpen(false);
        setNotice(
          "La serie cambió. Actualizamos su estado; revisa antes de volver a detenerla.",
        );
        router.refresh();
        return;
      }
      setNotice(
        "No se pudo detener la serie. Vuelve a cargarla e inténtalo otra vez.",
      );
    } catch {
      setNotice(
        "No se pudo confirmar la detención. Revisa el estado de la serie antes de reintentar.",
      );
    } finally {
      setIsSaving(false);
    }
  }

  return (
    <div className="flex flex-col items-start gap-2">
      <Button variant="danger" onClick={() => setIsOpen(true)}>
        Dejar de repetir
      </Button>
      {notice ? (
        <output className="text-sm text-text-secondary" aria-live="polite">
          {notice}
        </output>
      ) : null}
      <ConfirmDialog
        open={isOpen}
        onClose={() => setIsOpen(false)}
        onConfirm={() => void confirmStop()}
        title="Dejar de repetir"
        description="Se cancelarán las próximas apariciones. La tarjeta actual, sus conversaciones y el historial de esta serie se conservarán. Para volver a programar, se creará una serie nueva con la misma tarjeta como primera tarea."
        confirmLabel="Dejar de repetir"
        cancelLabel="Seguir repitiendo"
        loading={isSaving}
      />
    </div>
  );
}
