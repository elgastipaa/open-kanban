"use client";

import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";
import { MAX_LEGACY_BOARD_IMPORT_BYTES } from "@/lib/legacy-board-import";
import { MAX_PORTABLE_BOARD_IMPORT_BYTES } from "@/lib/portable-board-import-limits";

interface GenerationSummary {
  columns: number;
  tasks: number;
  comments: number;
  labels: number;
  birthdays: number;
  series: number;
  attachments: number;
  attachment_bytes: number;
}

interface CapacitySnapshot {
  limit_bytes: number;
  used_bytes: number;
  available_bytes: number;
  can_replace: boolean;
}

interface ImportPreview {
  status: "prepared";
  operation_id: string;
  content_revision: number;
  source_sha256?: string;
  expires_at: string;
  source_version: 1 | 2;
  current: GenerationSummary;
  imported?: GenerationSummary;
  capacity: CapacitySnapshot;
}

interface PendingPreparation {
  operationId: string;
  fileName: string;
  fileSize: number;
  fileLastModified: number;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function count(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : null;
}

function parseSummary(value: unknown): GenerationSummary | null {
  const row = asRecord(value);
  if (!row) return null;
  const columns = count(row.columns);
  const tasks = count(row.tasks);
  const comments = count(row.comments);
  const labels = count(row.labels);
  const birthdays = count(row.birthdays);
  const series = count(row.series);
  const attachments = count(row.attachments);
  const attachmentBytes = count(row.attachment_bytes);
  if (
    columns === null ||
    tasks === null ||
    comments === null ||
    labels === null ||
    birthdays === null ||
    series === null ||
    attachments === null ||
    attachmentBytes === null
  ) {
    return null;
  }
  return {
    columns,
    tasks,
    comments,
    labels,
    birthdays,
    series,
    attachments,
    attachment_bytes: attachmentBytes,
  };
}

function parseCapacity(value: unknown): CapacitySnapshot | null {
  const row = asRecord(value);
  if (!row) return null;
  const limit = count(row.limit_bytes);
  const used = count(row.used_bytes);
  const available = count(row.available_bytes);
  if (
    limit === null ||
    used === null ||
    available === null ||
    typeof row.can_replace !== "boolean"
  ) {
    return null;
  }
  return {
    limit_bytes: limit,
    used_bytes: used,
    available_bytes: available,
    can_replace: row.can_replace,
  };
}

function parsePreview(value: unknown): ImportPreview | null {
  const row = asRecord(value);
  if (
    !row ||
    row.status !== "prepared" ||
    typeof row.operation_id !== "string" ||
    typeof row.expires_at !== "string"
  ) {
    return null;
  }
  const revision = count(row.content_revision);
  const current = parseSummary(row.current);
  const imported =
    row.imported === undefined ? undefined : parseSummary(row.imported);
  const capacity = parseCapacity(row.capacity);
  const sourceVersion =
    row.source_version === undefined ? 1 : row.source_version;
  if (
    revision === null ||
    !current ||
    !capacity ||
    (sourceVersion !== 1 && sourceVersion !== 2) ||
    (row.imported !== undefined && !imported)
  ) {
    return null;
  }
  return {
    status: "prepared",
    operation_id: row.operation_id,
    content_revision: revision,
    source_sha256:
      typeof row.source_sha256 === "string" ? row.source_sha256 : undefined,
    expires_at: row.expires_at,
    source_version: sourceVersion,
    current,
    imported: imported ?? undefined,
    capacity,
  };
}

function describeError(body: unknown, fallback: string): string {
  const row = asRecord(body);
  if (row?.status === "conflict") {
    return "El tablero cambió desde la vista previa. Vuelve a preparar la operación y revisa el contenido actual.";
  }
  if (row?.status === "capacity") {
    return "No hay capacidad disponible para conservar los adjuntos de la versión anterior.";
  }
  if (row?.status === "expired") {
    return "La vista previa venció. Prepara la operación otra vez.";
  }
  if (typeof row?.message === "string") return row.message;
  return fallback;
}

function formatBytes(bytes: number): string {
  if (bytes < 1000) return `${bytes} bytes`;
  if (bytes < 1_000_000) return `${(bytes / 1000).toFixed(1)} KB`;
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

function describeGeneration(summary: GenerationSummary): string {
  const attachmentText =
    summary.attachments === 1 ? "1 adjunto" : `${summary.attachments} adjuntos`;
  return `${summary.columns} columnas, ${summary.tasks} tareas, ${summary.comments} comentarios, ${summary.labels} etiquetas, ${summary.birthdays} cumpleaños, ${summary.series} series y ${attachmentText} (${formatBytes(summary.attachment_bytes)})`;
}

function formatDate(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? "fecha no disponible"
    : date.toLocaleString();
}

interface BoardImportDialogProps {
  open: boolean;
  slug: string;
  onClose: () => void;
  onConfirmed: () => Promise<void>;
}

export function BoardImportDialog({
  open,
  slug,
  onClose,
  onConfirmed,
}: BoardImportDialogProps) {
  const [file, setFile] = useState<File | null>(null);
  const [importPreview, setImportPreview] = useState<ImportPreview | null>(
    null,
  );
  const [pendingPreparation, setPendingPreparation] =
    useState<PendingPreparation | null>(null);
  const [isPreparing, setIsPreparing] = useState(false);
  const [isConfirming, setIsConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setFile(null);
    setImportPreview(null);
    setError(null);
    setNotice(null);
  }, [open]);

  function handleClose() {
    if (isPreparing || isConfirming) return;
    onClose();
  }

  function handleFileChange(event: React.ChangeEvent<HTMLInputElement>) {
    const selected = event.target.files?.[0] ?? null;
    setFile(selected);
    setPendingPreparation((pending) =>
      selected &&
      pending?.fileName === selected.name &&
      pending.fileSize === selected.size &&
      pending.fileLastModified === selected.lastModified
        ? pending
        : null,
    );
    setImportPreview(null);
    setError(null);
    setNotice(null);
  }

  async function prepareImport() {
    if (!file || isPreparing) return;
    const isPortableV2 = file.name.toLowerCase().endsWith(".zip");
    const maximumBytes = isPortableV2
      ? MAX_PORTABLE_BOARD_IMPORT_BYTES
      : MAX_LEGACY_BOARD_IMPORT_BYTES;
    if (file.size > maximumBytes) {
      setError(
        isPortableV2
          ? "El respaldo ZIP supera el límite técnico permitido."
          : "El respaldo JSON supera el límite de 2 MiB.",
      );
      return;
    }
    setIsPreparing(true);
    setError(null);
    setNotice(null);
    try {
      const operationId =
        pendingPreparation?.operationId ?? crypto.randomUUID();
      setPendingPreparation({
        operationId,
        fileName: file.name,
        fileSize: file.size,
        fileLastModified: file.lastModified,
      });
      const endpoint = `/api/boards/${encodeURIComponent(slug)}/import`;
      const response = isPortableV2
        ? await fetch(endpoint, {
            method: "POST",
            body: file,
            cache: "no-store",
            headers: {
              "Content-Type": "application/zip",
              "X-Operation-Id": operationId,
            },
          })
        : await (() => {
            const form = new FormData();
            form.set("operation_id", operationId);
            form.set("file", file);
            return fetch(endpoint, {
              method: "POST",
              body: form,
              cache: "no-store",
            });
          })();
      const body: unknown = await response.json();
      if (response.ok && asRecord(body)?.status === "confirmed") {
        setPendingPreparation(null);
        setImportPreview(null);
        try {
          await onConfirmed();
          onClose();
        } catch {
          setNotice(
            "El reemplazo ya estaba confirmado, pero no se pudo actualizar la vista. Recarga la página para ver el contenido nuevo.",
          );
        }
        return;
      }
      const parsed = parsePreview(body);
      if (!response.ok || !parsed || parsed.source_sha256 === undefined) {
        if (
          [
            "cancelled",
            "capacity",
            "conflict",
            "expired",
            "invalid",
            "storage",
            "too_large",
            "unavailable",
          ].includes(String(asRecord(body)?.status))
        ) {
          setPendingPreparation(null);
        }
        setError(
          describeError(
            body,
            isPortableV2
              ? "No se pudo preparar el respaldo v2. El tablero actual no cambió."
              : "No se pudo preparar el respaldo v1.",
          ),
        );
        return;
      }
      setPendingPreparation(null);
      setImportPreview(parsed);
    } catch {
      setError(
        "No se pudo confirmar el resultado de la preparación. Vuelve a intentarlo con el mismo archivo para consultar la misma operación.",
      );
    } finally {
      setIsPreparing(false);
    }
  }

  async function confirmImport() {
    if (!importPreview?.source_sha256 || isConfirming) return;
    setIsConfirming(true);
    setError(null);
    setNotice(null);
    try {
      const response = await fetch(
        `/api/boards/${encodeURIComponent(slug)}/import/${encodeURIComponent(importPreview.operation_id)}/confirm`,
        {
          method: "POST",
          cache: "no-store",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            source_sha256: importPreview.source_sha256,
            expected_content_revision: importPreview.content_revision,
          }),
        },
      );
      const body: unknown = await response.json();
      if (!response.ok || asRecord(body)?.status !== "confirmed") {
        if (asRecord(body)?.status === "conflict") setImportPreview(null);
        setError(describeError(body, "No se pudo confirmar el reemplazo."));
        return;
      }
      setImportPreview(null);
      try {
        await onConfirmed();
        onClose();
      } catch {
        setNotice(
          "El reemplazo se confirmó, pero no se pudo actualizar la vista. Recarga la página para ver el contenido nuevo.",
        );
      }
    } catch {
      setError(
        "No se pudo confirmar el resultado del reemplazo. Vuelve a confirmar la misma vista previa sin volver a cargar el archivo.",
      );
    } finally {
      setIsConfirming(false);
    }
  }

  const busy = isPreparing || isConfirming;

  return (
    <Modal
      open={open}
      onClose={handleClose}
      title="Importar respaldos v1 o v2"
      fullScreenMobile
    >
      <div className="space-y-5 text-sm text-text-secondary leading-relaxed">
        <section className="space-y-3" aria-labelledby="board-import-heading">
          <h3
            id="board-import-heading"
            className="font-medium text-text-primary"
          >
            Reemplazar el contenido del tablero
          </h3>
          <p>
            Se reemplazará el contenido actual; no se combinarán las tareas. Se
            conservarán el propietario y los integrantes de este tablero.
          </p>
          <p>
            El respaldo v1 aporta columnas y tareas. El respaldo v2 puede
            incluir etiquetas, cumpleaños, comentarios, actividad, calendario de
            series y adjuntos. Los responsables antiguos quedan sin asignar y
            las menciones permanecen como texto; nunca se crean avisos antiguos.
          </p>
          <p>
            La versión anterior se conserva durante siete días. Sus adjuntos
            siguen contando para la capacidad mientras esté retenida.
          </p>
          <label className="block space-y-1.5 text-text-primary">
            <span>Archivo JSON v1 o ZIP v2</span>
            <input
              type="file"
              accept=".json,application/json,.zip,application/zip"
              onChange={handleFileChange}
              disabled={busy}
              className="block w-full rounded-md border border-border bg-surface-base px-3 py-2 text-text-secondary"
            />
          </label>
          {file ? (
            <p aria-live="polite">
              {file.name} · {formatBytes(file.size)}
            </p>
          ) : null}
          <div className="flex flex-wrap items-center gap-2">
            <Button
              variant="primary"
              onClick={() => void prepareImport()}
              disabled={!file || busy}
              aria-busy={isPreparing}
            >
              {isPreparing
                ? "Preparando vista previa…"
                : "Preparar vista previa"}
            </Button>
          </div>
          {importPreview?.imported ? (
            <div className="space-y-2 rounded-md border border-border bg-surface-raised p-3">
              <p>
                <strong className="text-text-primary">Contenido actual:</strong>{" "}
                {describeGeneration(importPreview.current)}
              </p>
              <p>
                <strong className="text-text-primary">
                  Respaldo v{importPreview.source_version}:
                </strong>{" "}
                {describeGeneration(importPreview.imported)}
              </p>
              <p>Revisión del contenido: {importPreview.content_revision}</p>
              <p>
                Capacidad utilizada:{" "}
                {formatBytes(importPreview.capacity.used_bytes)} de{" "}
                {formatBytes(importPreview.capacity.limit_bytes)}. Se
                conservarían{" "}
                {formatBytes(importPreview.current.attachment_bytes)} en
                adjuntos anteriores.
              </p>
              <p>
                Esta vista previa vence {formatDate(importPreview.expires_at)}.
                Vuelve a prepararla si el tablero cambia.
              </p>
              <div className="flex flex-wrap gap-2">
                <Button
                  variant="primary"
                  onClick={() => void confirmImport()}
                  disabled={busy || !importPreview.capacity.can_replace}
                  aria-busy={isConfirming}
                >
                  {isConfirming ? "Reemplazando…" : "Confirmar reemplazo"}
                </Button>
                <Button
                  onClick={() => {
                    setImportPreview(null);
                    setNotice(
                      "Vista previa descartada. El tablero actual no cambió.",
                    );
                  }}
                  disabled={busy}
                >
                  Descartar vista previa
                </Button>
              </div>
              {!importPreview.capacity.can_replace ? (
                <p role="alert" className="text-priority-urgent">
                  No se puede conservar la versión anterior con la capacidad
                  actual.
                </p>
              ) : null}
            </div>
          ) : null}
        </section>

        {error ? (
          <p role="alert" className="text-priority-urgent">
            {error}
          </p>
        ) : null}
        {notice ? (
          <output aria-live="polite" className="text-text-primary">
            {notice}
          </output>
        ) : null}
        <div className="flex justify-end border-border border-t pt-3">
          <Button onClick={handleClose} disabled={busy}>
            Cerrar
          </Button>
        </div>
      </div>
    </Modal>
  );
}
