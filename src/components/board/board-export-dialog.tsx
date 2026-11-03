"use client";

import { useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";

interface BoardExportDialogProps {
  open: boolean;
  slug: string;
  onClose: () => void;
}

export function BoardExportDialog({
  open,
  slug,
  onClose,
}: BoardExportDialogProps) {
  const [isExporting, setIsExporting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const isExportingRef = useRef(false);

  function handleClose() {
    if (isExportingRef.current) return;
    setError(null);
    onClose();
  }

  async function handleExport() {
    if (isExportingRef.current) return;
    isExportingRef.current = true;
    setIsExporting(true);
    setError(null);
    try {
      const response = await fetch(
        `/api/boards/${encodeURIComponent(slug)}/export`,
        { method: "POST", cache: "no-store" },
      );
      const result = (await response.json()) as {
        status?: unknown;
        export_id?: unknown;
      };
      if (
        !response.ok ||
        result.status !== "ready" ||
        typeof result.export_id !== "string"
      ) {
        throw new Error("No se pudo preparar la exportación.");
      }

      const download = document.createElement("a");
      download.href = `/api/boards/${encodeURIComponent(slug)}/export/${encodeURIComponent(result.export_id)}`;
      download.rel = "nofollow";
      download.hidden = true;
      document.body.append(download);
      download.click();
      download.remove();
      onClose();
    } catch {
      setError("No se pudo exportar el tablero completo. Inténtalo de nuevo.");
    } finally {
      isExportingRef.current = false;
      setIsExporting(false);
    }
  }

  return (
    <Modal open={open} onClose={handleClose} title="Exportar tablero completo">
      <div className="space-y-4 text-sm text-text-secondary leading-relaxed">
        <p>
          Se descargará una copia completa de los datos actuales del tablero,
          incluido su calendario, su actividad reciente y los adjuntos activos.
        </p>
        <p>
          El archivo es una copia portable. Quien lo reciba podrá conservar su
          contenido aunque después cambie el acceso al tablero.
        </p>
        {error && (
          <p role="alert" className="text-priority-urgent">
            {error}
          </p>
        )}
        <div className="flex items-center justify-end gap-2 pt-2">
          <Button variant="ghost" onClick={handleClose} disabled={isExporting}>
            Cancelar
          </Button>
          <Button
            variant="primary"
            onClick={() => void handleExport()}
            disabled={isExporting}
            aria-busy={isExporting}
          >
            {isExporting ? "Preparando copia…" : "Crear y descargar copia"}
          </Button>
        </div>
      </div>
    </Modal>
  );
}
