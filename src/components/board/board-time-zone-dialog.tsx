"use client";

import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";
import { BoardTimeZoneError } from "@/lib/db/boards";
import { formatTaskDueDate } from "@/lib/task-date";
import type { BoardTimeZonePreview } from "@/lib/types";

interface BoardTimeZoneDialogProps {
  open: boolean;
  onClose: () => void;
  timeZone: string;
  onPreview: (timeZone: string) => Promise<BoardTimeZonePreview>;
  onSave: (expectedTimeZone: string, timeZone: string) => Promise<void>;
}

function messageForError(error: unknown) {
  if (!(error instanceof BoardTimeZoneError)) {
    return "No se pudo confirmar el cambio. Vuelve a revisar la zona antes de intentarlo.";
  }
  switch (error.reason) {
    case "invalid_time_zone":
      return "Escribe una zona horaria IANA válida, por ejemplo America/Argentina/Buenos_Aires.";
    case "access_denied":
      return "Solo el propietario actual puede cambiar la zona horaria del tablero.";
    case "conflict":
      return "La zona cambió desde la vista previa. Vuelve a previsualizar el cambio.";
    case "uncertain":
      return "No se pudo confirmar el cambio. Revisa la zona horaria actual antes de volver a intentarlo.";
  }
}

export function BoardTimeZoneDialog({
  open,
  onClose,
  timeZone,
  onPreview,
  onSave,
}: BoardTimeZoneDialogProps) {
  const [draftTimeZone, setDraftTimeZone] = useState(timeZone);
  const [preview, setPreview] = useState<BoardTimeZonePreview | null>(null);
  const [error, setError] = useState("");
  const [isPreviewing, setIsPreviewing] = useState(false);
  const [isSaving, setIsSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    setDraftTimeZone(timeZone);
    setPreview(null);
    setError("");
  }, [open, timeZone]);

  async function makePreview() {
    if (isPreviewing || isSaving) return;
    setIsPreviewing(true);
    setError("");
    setPreview(null);
    try {
      setPreview(await onPreview(draftTimeZone));
    } catch (previewError) {
      setError(messageForError(previewError));
    } finally {
      setIsPreviewing(false);
    }
  }

  async function saveTimeZone() {
    if (
      isPreviewing ||
      isSaving ||
      !preview ||
      preview.time_zone !== timeZone ||
      preview.preview_time_zone !== draftTimeZone ||
      draftTimeZone === timeZone
    ) {
      return;
    }
    setIsSaving(true);
    setError("");
    try {
      await onSave(timeZone, draftTimeZone);
      onClose();
      setPreview(null);
    } catch (saveError) {
      setError(messageForError(saveError));
      setPreview(null);
    } finally {
      setIsSaving(false);
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Zona horaria del tablero"
      closeLabel="Cerrar zona horaria"
    >
      <div className="flex flex-col gap-4">
        <p className="text-sm text-text-secondary">
          Las fechas límite se interpretan en una sola zona para todas las
          personas del tablero.
        </p>
        <div className="flex flex-col gap-2">
          <label
            htmlFor="board-time-zone"
            className="font-medium text-sm text-text-primary"
          >
            Zona horaria IANA
          </label>
          <input
            id="board-time-zone"
            list="board-time-zone-options"
            value={draftTimeZone}
            disabled={isPreviewing || isSaving}
            aria-invalid={Boolean(error)}
            aria-describedby={error ? "board-time-zone-error" : undefined}
            onChange={(event) => {
              setDraftTimeZone(event.target.value);
              setPreview(null);
              setError("");
            }}
            autoComplete="off"
            className="h-11 w-full rounded-md border border-border bg-transparent px-3 text-sm text-text-primary outline-none focus:border-accent focus:ring-1 focus:ring-accent disabled:opacity-60"
          />
          <datalist id="board-time-zone-options">
            <option value="UTC" />
            <option value="America/Argentina/Buenos_Aires" />
            <option value="America/Mexico_City" />
            <option value="America/New_York" />
            <option value="America/Los_Angeles" />
            <option value="Europe/Madrid" />
            <option value="Europe/London" />
            <option value="Asia/Tokyo" />
            <option value="Pacific/Auckland" />
          </datalist>
        </div>
        {error && (
          <p
            id="board-time-zone-error"
            className="text-priority-urgent text-sm"
            role="alert"
          >
            {error}
          </p>
        )}
        {preview && preview.preview_time_zone === draftTimeZone && (
          <section
            className="space-y-2 rounded-md border border-border bg-surface-raised p-3"
            aria-label="Vista previa del cambio de zona horaria"
            aria-live="polite"
          >
            <p className="font-medium text-sm text-text-primary">
              Hoy: {formatTaskDueDate(preview.today_before)} en {timeZone} →{" "}
              {formatTaskDueDate(preview.today_after)} en {draftTimeZone}
            </p>
            <p className="text-sm text-text-secondary">
              Ahora: {preview.due_today_before} vencen hoy y{" "}
              {preview.overdue_before} están vencidas. Con la nueva zona:{" "}
              {preview.due_today_after} vencen hoy y {preview.overdue_after}{" "}
              están vencidas.
            </p>
            <p className="text-text-muted text-xs">
              Las fechas límite guardadas no cambiarán.
            </p>
          </section>
        )}
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button
            variant="ghost"
            onClick={onClose}
            disabled={isPreviewing || isSaving}
          >
            Cancelar
          </Button>
          <Button
            variant="ghost"
            onClick={() => void makePreview()}
            disabled={isPreviewing || isSaving || !draftTimeZone}
          >
            {isPreviewing ? "Previsualizando…" : "Vista previa"}
          </Button>
          {preview && draftTimeZone !== timeZone && (
            <Button
              variant="primary"
              onClick={() => void saveTimeZone()}
              disabled={isPreviewing || isSaving}
            >
              {isSaving ? "Guardando…" : "Confirmar zona"}
            </Button>
          )}
        </div>
      </div>
    </Modal>
  );
}
