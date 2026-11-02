"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { readTaskAttachmentDownloadResponse } from "@/lib/task-attachment-download";
import { generateUUID } from "@/lib/utils";

interface TaskAttachment {
  id: string;
  file_name: string;
  size_bytes: number;
  state: "active" | "recoverable";
  created_at: string;
  deleted_at: string | null;
  expires_at: string | null;
  can_restore: boolean;
  can_delete: boolean;
}

interface AttachmentCounts {
  active: number;
  recoverable: number;
}

interface AttachmentPage {
  attachments: TaskAttachment[];
  counts: AttachmentCounts;
}

interface PendingUpload {
  file: File;
  operationId: string;
}

interface PendingAttachmentAction {
  attachment: TaskAttachment;
  operationId: string;
}

interface TaskAttachmentsProps {
  slug: string;
  taskId: string;
  isOnline: boolean;
  isSessionStale: boolean;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseAttachment(value: unknown): TaskAttachment | null {
  if (
    !isRecord(value) ||
    typeof value.id !== "string" ||
    typeof value.file_name !== "string" ||
    typeof value.size_bytes !== "number" ||
    (value.state !== "active" && value.state !== "recoverable") ||
    typeof value.created_at !== "string" ||
    (value.deleted_at !== null && typeof value.deleted_at !== "string") ||
    (value.expires_at !== null && typeof value.expires_at !== "string") ||
    typeof value.can_restore !== "boolean" ||
    typeof value.can_delete !== "boolean"
  ) {
    return null;
  }
  return value as unknown as TaskAttachment;
}

function parseAttachmentPage(value: unknown): AttachmentPage | null {
  if (
    !isRecord(value) ||
    value.status !== "ok" ||
    !Array.isArray(value.attachments) ||
    !value.attachments.every((item) => parseAttachment(item) !== null) ||
    !isRecord(value.counts) ||
    typeof value.counts.active !== "number" ||
    typeof value.counts.recoverable !== "number" ||
    !Number.isSafeInteger(value.counts.active) ||
    !Number.isSafeInteger(value.counts.recoverable)
  ) {
    return null;
  }
  return {
    attachments: value.attachments.map(parseAttachment) as TaskAttachment[],
    counts: {
      active: value.counts.active,
      recoverable: value.counts.recoverable,
    },
  };
}

function formatTimestamp(value: string | null): string {
  if (!value) return "";
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "Fecha desconocida";
  return new Intl.DateTimeFormat("es-AR", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function requestErrorMessage(value: unknown, fallback: string): string {
  return isRecord(value) && typeof value.message === "string"
    ? value.message
    : fallback;
}

export function TaskAttachments({
  slug,
  taskId,
  isOnline,
  isSessionStale,
}: TaskAttachmentsProps) {
  const collectionUrl = useMemo(
    () =>
      `/api/boards/${encodeURIComponent(slug)}/tasks/${encodeURIComponent(taskId)}/attachments`,
    [slug, taskId],
  );
  const [attachments, setAttachments] = useState<TaskAttachment[]>([]);
  const [counts, setCounts] = useState<AttachmentCounts>({
    active: 0,
    recoverable: 0,
  });
  const [isLoading, setIsLoading] = useState(true);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [pendingUpload, setPendingUpload] = useState<PendingUpload | null>(
    null,
  );
  const [isUploading, setIsUploading] = useState(false);
  const [downloadingAttachmentId, setDownloadingAttachmentId] = useState<
    string | null
  >(null);
  const [pendingDelete, setPendingDelete] =
    useState<PendingAttachmentAction | null>(null);
  const [pendingRestore, setPendingRestore] =
    useState<PendingAttachmentAction | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [busyAttachmentId, setBusyAttachmentId] = useState<string | null>(null);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");

  const load = useCallback(
    async (signal?: AbortSignal) => {
      const response = await fetch(collectionUrl, {
        cache: "no-store",
        signal,
      });
      const payload: unknown = await response.json().catch(() => null);
      const page = parseAttachmentPage(payload);
      if (!response.ok || !page) {
        setAttachments([]);
        setCounts({ active: 0, recoverable: 0 });
        throw new Error("No se pudieron consultar los archivos de esta tarea.");
      }
      setAttachments(page.attachments);
      setCounts(page.counts);
      setError("");
    },
    [collectionUrl],
  );

  useEffect(() => {
    if (isSessionStale) {
      setAttachments([]);
      setCounts({ active: 0, recoverable: 0 });
      setPendingUpload(null);
      setError("Los archivos de esta tarea ya no están disponibles.");
      setIsLoading(false);
      return;
    }
    if (!isOnline) {
      setAttachments([]);
      setCounts({ active: 0, recoverable: 0 });
      setError("Conéctate para consultar los archivos de esta tarea.");
      setIsLoading(false);
      return;
    }

    const controller = new AbortController();
    setIsLoading(true);
    void load(controller.signal)
      .catch(() => {
        if (!controller.signal.aborted) {
          setError("No se pudieron consultar los archivos de esta tarea.");
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) setIsLoading(false);
      });
    return () => controller.abort();
  }, [isOnline, isSessionStale, load]);

  async function refresh() {
    setIsRefreshing(true);
    try {
      await load();
      setNotice("Lista actualizada.");
    } catch {
      setError("No se pudieron consultar los archivos de esta tarea.");
    } finally {
      setIsRefreshing(false);
    }
  }

  async function upload(intent: PendingUpload) {
    setIsUploading(true);
    setNotice("Reservando espacio, cargando y verificando el archivo…");
    setError("");
    try {
      const response = await fetch(collectionUrl, {
        method: "POST",
        cache: "no-store",
        headers: {
          "Content-Type": "text/plain",
          "Idempotency-Key": intent.operationId,
          "X-File-Name": encodeURIComponent(intent.file.name),
        },
        body: intent.file,
      });
      const result: unknown = await response.json().catch(() => null);
      if (!response.ok || !isRecord(result) || result.status !== "confirmed") {
        const message = requestErrorMessage(
          result,
          "No se pudo confirmar la carga. Revisa el listado antes de volver a intentarlo.",
        );
        setNotice("");
        if (
          response.status >= 400 &&
          response.status < 500 &&
          response.status !== 409 &&
          response.status !== 429
        ) {
          setPendingUpload(null);
        }
        await load().catch(() => undefined);
        setError(message);
        return;
      }
      setPendingUpload(null);
      setNotice("Archivo disponible para miembros autorizados.");
      await load();
    } catch {
      setNotice("");
      await load().catch(() => undefined);
      setError(
        "No se pudo confirmar la carga. Conserva el borrador y vuelve a intentar para reconciliar el mismo envío.",
      );
    } finally {
      setIsUploading(false);
    }
  }

  function chooseFile(event: React.ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    if (file.size < 1) {
      setError("El archivo está vacío.");
      return;
    }
    if (file.size > 24_000) {
      setError("El archivo no puede superar 24.000 bytes.");
      return;
    }
    if (!/\.(txt|md)$/iu.test(file.name)) {
      setError("Solo se admiten archivos .txt o .md.");
      return;
    }
    const intent = { file, operationId: generateUUID() };
    setPendingUpload(intent);
    setError("");
    void upload(intent);
  }

  async function downloadAttachment(attachment: TaskAttachment) {
    if (!canInteract || downloadingAttachmentId !== null) return;
    setDownloadingAttachmentId(attachment.id);
    setError("");
    setNotice("");
    try {
      const response = await fetch(`${collectionUrl}/${attachment.id}`, {
        cache: "no-store",
      });
      const result = await readTaskAttachmentDownloadResponse(response);
      if (result.status === "missing") {
        setAttachments((current) =>
          current.filter((item) => item.id !== attachment.id),
        );
        setCounts((current) => ({
          ...current,
          active: Math.max(0, current.active - 1),
        }));
        setNotice(result.message);
        await load().catch(() => {
          setError("No se pudo actualizar el listado de archivos.");
        });
        return;
      }
      if (result.status === "failed") {
        await load().catch(() => undefined);
        setError(result.message);
        return;
      }

      const objectUrl = URL.createObjectURL(result.blob);
      const link = document.createElement("a");
      link.href = objectUrl;
      link.download = attachment.file_name;
      link.referrerPolicy = "no-referrer";
      link.hidden = true;
      document.body.append(link);
      link.click();
      link.remove();
      window.setTimeout(() => URL.revokeObjectURL(objectUrl), 1000);
      setNotice("Descarga iniciada.");
    } catch {
      setError("No se pudo descargar el archivo.");
    } finally {
      setDownloadingAttachmentId(null);
    }
  }

  async function deleteAttachment() {
    if (!pendingDelete) return;
    const { attachment, operationId } = pendingDelete;
    setIsDeleting(true);
    setError("");
    try {
      const response = await fetch(`${collectionUrl}/${attachment.id}`, {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ operation_id: operationId }),
      });
      const result: unknown = await response.json().catch(() => null);
      if (!response.ok || !isRecord(result) || result.status !== "confirmed") {
        throw new Error(
          "No se pudo borrar el archivo. Actualiza el listado antes de reintentar.",
        );
      }
      setPendingDelete(null);
      setNotice("Archivo enviado a recuperación durante siete días.");
      await load();
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "No se pudo borrar el archivo.";
      await load().catch(() => undefined);
      setError(message);
    } finally {
      setIsDeleting(false);
    }
  }

  async function restoreAttachment(intent: PendingAttachmentAction) {
    const { attachment, operationId } = intent;
    setPendingRestore(intent);
    setBusyAttachmentId(attachment.id);
    setError("");
    try {
      const response = await fetch(`${collectionUrl}/${attachment.id}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ operation_id: operationId }),
      });
      const result: unknown = await response.json().catch(() => null);
      if (!response.ok || !isRecord(result) || result.status !== "confirmed") {
        throw new Error(
          "No se pudo recuperar el archivo. Puede haber vencido el plazo.",
        );
      }
      setPendingRestore(null);
      setNotice("Archivo recuperado y disponible para miembros autorizados.");
      await load();
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "No se pudo recuperar el archivo.";
      await load().catch(() => undefined);
      setError(message);
    } finally {
      setBusyAttachmentId(null);
    }
  }

  const canInteract = isOnline && !isSessionStale;
  return (
    <section
      className="border-border border-t pt-3"
      aria-labelledby="task-attachments-heading"
    >
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h3
            id="task-attachments-heading"
            className="font-semibold text-sm text-text-primary"
          >
            Archivos privados
          </h3>
          <p className="mt-1 text-text-muted text-xs">
            {counts.active} activos + {counts.recoverable} en recuperación / 20
            · hasta 24.000 bytes por archivo · .txt o .md
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button
            size="sm"
            onClick={() => void refresh()}
            disabled={!canInteract || isRefreshing || isLoading}
          >
            {isRefreshing ? "Actualizando…" : "Actualizar"}
          </Button>
          <label
            className={`inline-flex min-h-10 cursor-pointer items-center rounded-md bg-accent px-3 font-medium text-accent-foreground text-sm hover:bg-accent-hover ${!canInteract || isUploading || isLoading || pendingUpload ? "cursor-not-allowed opacity-50" : ""}`}
          >
            {isUploading ? "Cargando…" : "Adjuntar texto"}
            <input
              type="file"
              accept=".txt,.md,text/plain"
              aria-label="Adjuntar archivo de texto .txt o .md"
              className="sr-only"
              disabled={
                !canInteract ||
                isUploading ||
                isLoading ||
                pendingUpload !== null
              }
              onChange={chooseFile}
            />
          </label>
        </div>
      </div>

      {pendingUpload && !isUploading ? (
        <div className="mt-3 flex flex-wrap items-center gap-2 rounded-md border border-priority-medium/30 bg-priority-medium/10 p-3 text-sm">
          <p className="min-w-0 flex-1 break-words">
            No se confirmó «{pendingUpload.file.name}». Reintentar usa el mismo
            envío para reconciliarlo.
          </p>
          <Button
            size="sm"
            onClick={() => void upload(pendingUpload)}
            disabled={!canInteract}
          >
            Reintentar confirmación
          </Button>
        </div>
      ) : null}

      {isLoading ? (
        <output className="mt-3 text-sm text-text-muted">
          Consultando archivos…
        </output>
      ) : error ? null : attachments.length === 0 ? (
        <p className="mt-3 text-sm text-text-muted">
          Todavía no hay archivos publicados.
        </p>
      ) : (
        <ul className="mt-3 divide-y divide-border rounded-md border border-border">
          {attachments.map((attachment) => (
            <li
              key={attachment.id}
              className="flex flex-wrap items-center justify-between gap-3 p-3"
            >
              <div className="min-w-0">
                <p className="break-words font-medium text-sm text-text-primary">
                  {attachment.file_name}
                </p>
                <p className="mt-1 text-text-muted text-xs">
                  {attachment.size_bytes.toLocaleString("es-AR")} bytes
                  {attachment.state === "recoverable" && attachment.expires_at
                    ? ` · Recuperable hasta ${formatTimestamp(attachment.expires_at)}`
                    : ` · Subido ${formatTimestamp(attachment.created_at)}`}
                </p>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                {attachment.state === "active" ? (
                  <Button
                    size="sm"
                    className="min-h-10 border border-border px-3 text-sm"
                    onClick={() => void downloadAttachment(attachment)}
                    disabled={!canInteract || downloadingAttachmentId !== null}
                    aria-busy={downloadingAttachmentId === attachment.id}
                    aria-label={
                      downloadingAttachmentId === attachment.id
                        ? `Descargando ${attachment.file_name}`
                        : `Descargar ${attachment.file_name}`
                    }
                  >
                    {downloadingAttachmentId === attachment.id
                      ? "Descargando…"
                      : "Descargar"}
                  </Button>
                ) : null}
                {attachment.can_restore ? (
                  <Button
                    size="sm"
                    onClick={() =>
                      void restoreAttachment(
                        pendingRestore?.attachment.id === attachment.id
                          ? pendingRestore
                          : { attachment, operationId: generateUUID() },
                      )
                    }
                    disabled={
                      !canInteract || busyAttachmentId === attachment.id
                    }
                  >
                    {busyAttachmentId === attachment.id
                      ? "Recuperando…"
                      : pendingRestore?.attachment.id === attachment.id
                        ? "Reintentar recuperación"
                        : "Recuperar"}
                  </Button>
                ) : null}
                {attachment.can_delete ? (
                  <Button
                    size="sm"
                    variant="danger"
                    onClick={() =>
                      setPendingDelete({
                        attachment,
                        operationId: generateUUID(),
                      })
                    }
                    disabled={!canInteract || isDeleting}
                  >
                    Borrar
                  </Button>
                ) : null}
              </div>
            </li>
          ))}
        </ul>
      )}

      {notice ? (
        <output
          className="mt-2 block text-text-secondary text-xs"
          aria-live="polite"
        >
          {notice}
        </output>
      ) : null}
      {error ? (
        <output
          className="mt-2 block text-priority-urgent text-xs"
          role="alert"
        >
          {error}
        </output>
      ) : null}
      {!isOnline ? (
        <p className="mt-2 text-text-muted text-xs">
          Los archivos requieren conexión.
        </p>
      ) : null}

      <ConfirmDialog
        open={pendingDelete !== null}
        onClose={() => {
          if (!isDeleting) setPendingDelete(null);
        }}
        onConfirm={() => void deleteAttachment()}
        title="Borrar archivo"
        description={
          pendingDelete
            ? `«${pendingDelete.attachment.file_name}» dejará de estar disponible y se podrá recuperar hasta ${formatTimestamp(pendingDelete.attachment.expires_at)}. La cuota se libera solo después de la purga.`
            : ""
        }
        confirmLabel="Enviar a recuperación"
        cancelLabel="Cancelar"
        loading={isDeleting}
      />
    </section>
  );
}
